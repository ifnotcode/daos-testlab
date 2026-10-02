# daos-testlab

Лаборатория для тестирования DAOS на VM libvirt. Вся конфигурация хранится в этом репозитории, и
лабораторию можно пересоздать с нуля одной командой.

Лаборатория умеет:
- создавать VM по описанию в `lab.conf`: сервер DAOS, клиентские хосты, узел kubeadm с gVisor и
  узел Talos;
- собирать многоузловой kubeadm-кластер: узел роли `k8s` становится control plane, узлы роли
  `k8s-worker` подключаются к нему. В конфигурации без сервера DAOS узлы получают чистый
  Kubernetes (так устроены стенды курса в `../k8Learning/stands/`);
- поднимать на них систему DAOS: сервер, пул, POSIX-контейнер, агенты и маршруты для pod-сетей;
- собирать DAOS из исходников с набором патчей: RPM и дерево `/opt/daos` для EL9, tarball для
  Ubuntu по QSG, клиентский образ и образ CSI;
- ставить сборку на VM и запускать тесты с итоговой таблицей PASS/FAIL.

Выросло из проверки патча `dfuse --allow-idmap` (поды Kubernetes с `hostUsers: false` на томах
dfuse). Его тесты — `tests/dfuse-idmap.sh`, `tests/k8s-allow-idmap.sh`, `tests/nlt.sh` — служат
примерами для новых задач.

## Что нужно

- **Рабочая машина.** Нужны bash (подойдёт и 3.2 из macOS), ssh и tar. Все остальные действия
  выполняются на хосте и на VM через ssh.
- **libvirt-хост.** AlmaLinux 9 или аналог с libvirt, `virt-install`, `genisoimage`, `podman`,
  `curl`.
  - Пользователь хоста состоит в группе `libvirt`; sudo на хосте не нужен.
  - Нужна NAT-сеть `default`.
  - Нужен каталог для больших файлов: `LAB_HOST_STORE`, сейчас это внешний SSD
    `/mnt/keenetic/daos-testlab`. Там лежат storage pool `testlab` (`pool/`, его создаёт
    `lab check`), сборки (`builds/`), кеш загрузок (`cache/`) и образы памяти приостановленных
    VM (`saved/`).
  - `bin/lab check` проверяет всё это и показывает свободное место и память.
- **ssh-ключ** (`SSH_KEY` в `lab.conf`). Он должен пускать на хост, а его публичная часть
  прописывается в VM.

## Быстрый старт

```bash
bin/lab check                 # готов ли хост
bin/lab up                    # все VM из lab.conf: сначала сервер, потом остальные
bin/lab status                # VM и их память, ядра, службы DAOS, пулы
bin/lab test smoke client-1   # базовая проверка клиента
bin/lab suspend               # освободить память хоста: VM сохраняются на SSD
```

`up`, `create` и `provision` идемпотентны. Если шаг упал, его можно просто запустить ещё раз:
существующие VM не пересоздаются, а шаги настройки проверяют, что уже сделано. Когда шагу нужна
перезагрузка (ядро, THP), он выходит с кодом 100. `lab` сам перезагружает VM и повторяет шаг.

## Питание VM и память

Все VM сразу почти не помещаются в память хоста (31 GB), поэтому VM работают, только пока они
нужны. Остановленная или приостановленная VM память хоста не занимает.

```bash
bin/lab status                  # состояние VM, занятая ими и свободная память хоста
bin/lab suspend client-1 k8s-1  # сохранить память VM на SSD и остановить (секунды)
bin/lab start client-1          # восстановить или загрузить VM и дождаться готовности
bin/lab stop                    # выключить все VM, сервер последним
```

- **`start`** (или `resume`) поднимает VM, начиная с сервера, и ждёт готовности каждой: у сервера
  есть пул и контейнер, клиенты видят пул, узлы Kubernetes в состоянии Ready. Приостановленную VM
  он восстанавливает из образа памяти и выставляет ей часы через гостевой агент.
- **`suspend`** сохраняет память VM в `$LAB_HOST_STORE/saved/<lab>/` (`virsh save`). Образ размером
  с занятую гостем память: около 2 GB у client-1 и 3 GB у daos-1. Talos вместо этого
  выключается: гостевого агента для часов у него нет, а состояние и так на диске.
- **`stop`** выключает VM по ACPI, через 3 минуты принудительно.
- **Сервер.** SCM лежит в tmpfs, поэтому после `stop` пул пропадает. `start` заново настраивает его
  (как `provision`, около 2 минут), перезапускает агентов на работающих клиентах и напоминает, что
  прежние монтирования dfuse больше не работают. `suspend` сохраняет пул вместе с памятью.
- **Команды, которым нужна VM** (`ssh`, `test`, `deploy`, `copy`, `csi`, `kubectl`), для
  остановленной VM сразу подсказывают `lab start`. `provision` запускает её сам.
- **Без автозапуска, с возвратом памяти.** VM создаются без autostart. virtio-balloon с free page
  reporting возвращает хосту память, которую освободил гость: k8s-1 после NLT больше не держит
  11 GB. У VM, созданных раньше, это включает `start`, а действует с ближайшего холодного старта
  (`stop`, затем `start`). До этого `status` помечает их `autostart` и `no-page-reporting`.
- После перезагрузки хоста VM сами не стартуют: `bin/lab start` или только нужные.

### Сценарии

Разные задачи требуют разных VM, и все сразу держать не нужно.
- **`VM_GROUPS` в `lab.conf`.** Группы описаны ролями, поэтому годятся и для профилей:

  | Группа | VM |
  |---|---|
  | `plain` | сервер и клиент |
  | `kubeadm` | сервер и k8s-1 |
  | `talos-cluster` | сервер и talos-1 |
  | `nlt` | только k8s-1: NLT поднимает свой сервер |
  | `multinode` | все |

- **Где работают группы.** В `start`, `stop` и `suspend` вместо имён VM можно указывать группы и
  роли.
- **`lab use <группа>`** оставляет работать только VM группы: остальные приостанавливает, эти
  поднимает. Без аргумента команда показывает группы.
- **`lab test` сам готовит VM.** Каждый набор объявляет в шапке, что ему нужно помимо VM, на
  которой он идёт: `# needs: server` или `# needs: none`. Недостающее `lab test` поднимает.
  - Если памяти мало, он приостанавливает ненужные VM, начиная с самых больших, сервер
    последним. Хосту при этом оставляется `HOST_MEM_RESERVE_GB`.
  - `--exclusive` приостанавливает все ненужные VM, например, чтобы у NLT было больше памяти.
  - После прогона VM, которые поднял тест, снова приостанавливаются. `--keep` оставляет их
    работать.
- **`lab kernel <vm> stock|ml`** загружает VM в её новейшее стоковое ядро или в kernel-ml, чтобы
  проверить одно и то же на обоих. Переключение действует до следующего `provision`, который
  вернёт ядро из `lab.conf`. Без аргумента команда показывает установленные ядра.

```bash
bin/lab use plain                      # только daos-1 и client-1
bin/lab kernel client-1 stock          # Alma 9.7 на стоковом ядре 5.14
bin/lab test smoke client-1
bin/lab kernel client-1 ml
bin/lab test --exclusive nlt k8s-1     # NLT один: сервер и клиент приостановлены
```

## Пересоздание с нуля

Всё состояние лаборатории выводится из `lab.conf`, скриптов и внешних источников (облачные образы
AlmaLinux, packages.daos.io, ELRepo, релизы Kubernetes, Talos Image Factory). Если VM или весь
хост потеряны:

```bash
bin/lab destroy daos-1 k8s-1 client-1 talos-1 --yes   # если что-то осталось
bin/lab up
```

Порядок и роли VM берутся из `VMS` в `lab.conf`:
- **`server`**: DAOS server, `dmg`, пул `POOL`, контейнер `CONT`, реестр образов;
- **`client`**: DAOS client, `daos_agent`;
- **`k8s`**: DAOS client, kubeadm, containerd, runc, flannel, gVisor;
- **`talos`**: Talos с расширением gVisor.

Talos генерирует секреты кластера один раз, в `~/daos-testlab/<lab>/talos/` на хосте. Если они
потеряны, узел Talos нужно пересоздать (`destroy` и `up`).

Скачанные образы (AlmaLinux, Talos) и утилиты хранятся в кеше `$LAB_HOST_STORE/cache`. Поэтому
пересоздание не зависит от того, что за это время поменялось по ссылкам `latest`.

Что **не** восстанавливается само и хранится вне VM:
- **Сборки** в `$LAB_HOST_STORE/builds/`. Их пересобирает `lab build`.
- **Образы в реестре** на server-VM. Их заново выкладывают `lab build csi` и `lab images push`.

### Что проверено

26.09.2026 на хосте 192.168.1.83 независимая лаборатория `profiles/verify.conf` была поднята с
пустого места:
- **сервер и клиент** — около 20 минут;
- **узел k8s** — около 25 минут;
- **узел Talos** — несколько минут.

После этого прошли тесты:

| Проверка | Результат |
|----------|-----------|
| `smoke` на релизе 2.8.0 | 9/9 |
| `smoke` и `dfuse-idmap` на `@el9-v2.8.0-allow-idmap-v2.8.0` | 9/9 и 22/22 |
| `ubuntu-bin` с `@ubuntu-24.04-v2.8.0-allow-idmap-v2.8.0` | 22/22 |
| `k8s-smoke` на kubeadm и на Talos | 4/4 и 4/4 |
| `k8s-allow-idmap` через CSI на kubeadm и на Talos | 15/15 и 15/15 |

Кроме того, проверены:
- возврат с тестовой сборки на релиз (`deploy release`) и обратно;
- повторный `provision` всех ролей;
- восстановление сервера после перезагрузки.

27.09.2026 основная лаборатория (`lab.conf`) была удалена и поднята этими скриптами с нуля.

- **VM:** все четыре VM и их базовые образы лежат в пуле `testlab` на внешнем SSD.
- **Реестр образов:** `192.168.122.20:5000` на daos-1.
- **Talos:** кластер создан с новыми секретами.
- **DAOS на client-1 и k8s-1:** сборка `@el9-master-0dbc4dd-allow-idmap`, то есть master на
  коммите 0dbc4dd с `patchsets/allow-idmap-master`. Сборка заняла около 55 минут.
  - На обе VM поставлены RPM.
  - На k8s-1 также поставлены дерево `/opt/daos` и исходники `~/daos-src`.
- **CSI** на k8s-1 и talos-1 развёрнут с образом `daos-csi:master-0dbc4dd-idmap`.

После этого прошли тесты:

| Проверка | Результат |
|----------|-----------|
| `smoke` на client-1 | 9/9 |
| `dfuse-idmap` на client-1 (RPM) и на k8s-1 (`/opt/daos`) | 22/22 и 22/22 |
| `nlt --test il_allow_idmap` на k8s-1 | 5 passed |
| `k8s-smoke` на k8s-1 и talos-1 | 4/4 и 4/4 |
| `k8s-allow-idmap` на k8s-1 и talos-1 | 15/15 и 15/15 |

Позже 27.09.2026 патч дополнен: отказ в handles при `/dev/fd/N` и проверки этого в `dfuse-idmap`.
Сборка `@el9-master-0dbc4dd-allow-idmap-r2` (около 25 минут, слои из кеша) поставлена так же и
заменила прежнюю на client-1 и k8s-1. CSI развёрнут с образом `daos-csi:master-0dbc4dd-idmap-r2`.
Прежняя сборка осталась на хосте для сравнения.

01.10.2026 на k8s-1 развёрнут образ CSI `daos-csi:master-0dbc4dd-idmap-r3` на той же сборке клиента.
В нём метрики Prometheus, `/healthz` и `/readyz` (порт 9810 у плагина узла, 9811 у контроллера) и
параметры логов. Результаты: `k8s-smoke` 4/4, `k8s-allow-idmap` 15/15, `k8s-multi-pod` 33/33. На
talos-1 остался `-r2`.

Затем на k8s-1 развёрнут `-r5`, в нём добавлены ресурсы dfuse в mount-подах. Результаты:
`k8s-csi-resources` 15/15, `k8s-allow-idmap` 15/15, `k8s-multi-pod` 33/33. Что выяснилось:
- **kubelet выселяет поды с меньшим приоритетом**, чтобы принять mount-под
  (`system-node-critical`) с requests.
- **Лимит без request:** Kubernetes поставил бы request = limit, поэтому драйвер ставит request 0.
- **Лимит CPU 200m** снижает скорость записи одного писателя через dfuse со 135–180 до 40–55 МБ/с (по нескольким прогонам).

| Проверка | Результат |
|----------|-----------|
| `smoke` на client-1 | 9/9 |
| `dfuse-idmap` на client-1 (RPM) и на k8s-1 (`/opt/daos`) | 28/28 и 28/28 |
| `nlt --test il_allow_idmap` на k8s-1 | 5 passed |
| `k8s-allow-idmap` на k8s-1 и talos-1 | 15/15 и 15/15 |
| `dfuse-idmap` на прежней сборке (негативный контроль) | 26/28: две проверки `/dev/fd/N` в режиме `allow` |

Потом там же проверены команды питания VM:
- **`suspend` и `start`.** client-1 сохраняется за 5 секунд и восстанавливается за 9, daos-1 — за
  9 и 12 секунд, и пул остаётся тем же. Часы восстановленной VM выставляются.
- **Холодные `stop` и `start` всех VM.** Сервер заново создаёт пул примерно за 2 минуты, агенты на
  работающих k8s-1 и talos-1 перезапускаются, восстановленный client-1 видит новый пул.
- **Free page reporting.** k8s-1 занимал 10,7 GB, после холодного старта — 2,5 GB. Если в госте
  занять и освободить 3 GB, хост получает их обратно за 20 секунд. Свободная память хоста выросла
  с 3,7 до 15 GB.
- **После этого** прошли `smoke` 9/9, `dfuse-idmap` 28/28 и `k8s-allow-idmap` 15/15 на k8s-1 и
  talos-1.

Затем проверены сценарии:
- **`lab use plain`.** k8s-1 приостанавливается, talos-1 выключается, свободно 19,8 GB.
- **`lab test k8s-smoke talos-1` на выключенном talos-1.** Узел поднимается, прогон 4/4, после
  прогона узел снова выключается.
- **`lab kernel client-1 stock`.** Alma 9.7 на ядре 5.14.0-611 загружается за 19 секунд, `smoke`
  проходит 9/9. Затем client-1 возвращается на ml.
- **`lab test --exclusive nlt k8s-1`.** daos-1 и client-1 приостанавливаются, `il_allow_idmap`
  проходит 5/5, k8s-1 после прогона снова приостанавливается.
- **Освобождение памяти.** С `HOST_MEM_RESERVE_GB=21` `lab test` приостанавливает client-1, потом
  daos-1, пока образ k8s-1 не помещается.

Затем тесты расширены, сборка `@el9-master-0dbc4dd-allow-idmap-r2`:

| Проверка | Результат |
|----------|-----------|
| `dfuse-unit` на client-1, ядра 7.2 и 5.14, dfuse от admin и от root | 45/45 × 4 |
| `dfuse-client` на client-1, ядра 7.2 и 5.14 | 39/39 и 39/39 |
| `podman-idmap` на client-1 | 10/10 |
| `k8s-multi-pod` на k8s-1 и talos-1 | 33/33 и 33/33 |
| `nlt` полностью на k8s-1, без опции и с `FORCE_IDMAP=1` | 87/87 и 87/87 |
| `ftest` (`profiles/ftest.conf`), без опции и с `FORCE_IDMAP=1` | одинаково: 38 PASS, остальные падают и без патча |

Контрольная сборка master без патчей — `@el9-master-0dbc4dd-baseline`. На ней воспроизводятся
падения ftest `test_bashfd_pil4dfs` и шаг fio/libaio в `test_bashcmd_pil4dfs*`
(`docs/gotchas.md`).

Чтобы повторить с нуля:

```bash
bin/lab up
bin/lab build el9 --ref 0dbc4ddda51cbb44bdc1aaa53913a10efc378397 \
    --patches patchsets/allow-idmap-master --name el9-master-0dbc4dd-allow-idmap-r2
B=@el9-master-0dbc4dd-allow-idmap-r2
bin/lab deploy client-1 rpms $B
bin/lab deploy k8s-1 rpms $B && bin/lab deploy k8s-1 tree $B && bin/lab deploy k8s-1 src $B
bin/lab images push localhost/daos-client:el9-master-0dbc4dd-allow-idmap-r2
bin/lab build csi localhost/daos-client:el9-master-0dbc4dd-allow-idmap-r2 master-0dbc4dd-idmap-r2
bin/lab csi k8s-1 @master-0dbc4dd-idmap-r2 && bin/lab csi talos-1 @master-0dbc4dd-idmap-r2
```

## Вторая лаборатория (профили)

`-c <файл>` подключает профиль поверх `lab.conf`, и получается независимая лаборатория на том же
хосте со своими VM, IP и пулом. Пример — `profiles/verify.conf`. С его помощью проверялось, что
лаборатория поднимается с нуля.

```bash
bin/lab -c profiles/verify.conf up
bin/lab -c profiles/verify.conf test smoke vclient-1
bin/lab -c profiles/verify.conf destroy vdaos-1 vk8s-1 vclient-1 vtalos-1 --yes
```

Имена, IP и MAC в разных профилях не должны пересекаться. Сгенерированные файлы лежат в
`work/<профиль>/` локально и в `~/daos-testlab/<профиль>/` на хосте.

`profiles/ftest.conf` — две VM для функциональных тестов самого DAOS (avocado, `launch.py`), как
их гоняет upstream CI на VM. Порядок команд описан в шапке профиля, набор — в
[tests/README.md](tests/README.md) (раздел ftest). Перед запуском основную лабораторию стоит
приостановить: `bin/lab suspend`.

`profiles/rdma.conf` — лаборатория с DAOS по RDMA: провайдер `ofi+verbs;ofi_rxm` на Soft-RoCE,
потому что RDMA-железа на хосте нет. В ней три VM: сервер, клиент и узел kubeadm.
- DAOS сам не видит программные RDMA-устройства, поэтому вся лаборатория ставит сборку с
  `patchsets/soft-rdma` (`DAOS_BUILD` в профиле).
- Подробности и остальные особенности — в [docs/gotchas.md](docs/gotchas.md), раздел «RDMA без
  железа».

```bash
bin/lab suspend                                    # основная лаборатория: память
bin/lab build el9 --ref 0dbc4ddda51cbb44bdc1aaa53913a10efc378397 --patches patchsets/allow-idmap-master \
    --patches patchsets/soft-rdma --name el9-master-0dbc4dd-idmap-softrdma
bin/lab -c profiles/rdma.conf up
bin/lab -c profiles/rdma.conf test dfuse-idmap rclient-1
bin/lab -c profiles/rdma.conf images push localhost/daos-client:el9-master-0dbc4dd-idmap-softrdma
bin/lab -c profiles/rdma.conf build csi localhost/daos-client:el9-master-0dbc4dd-idmap-softrdma softrdma
bin/lab -c profiles/rdma.conf csi rk8s-1 @softrdma
bin/lab -c profiles/rdma.conf test k8s-rdma rk8s-1 CLIENT_IMAGE=@el9-master-0dbc4dd-idmap-softrdma
```

Проверено 30.09.2026 на master `0dbc4dd` с обоими PR и soft-rdma:

| Тест | Результат |
|---|---|
| `smoke` (с проверкой провайдера) | 10/10 |
| `dfuse-idmap` | 28/28 |
| `k8s-smoke` | 4/4 |
| `k8s-allow-idmap` | 15/15 |
| `k8s-rdma` | 7/7 |

## Проверка своего DAOS

```bash
# DAOS из исходников: ref на GitHub и каталог с патчами (применяются по порядку, git apply)
bin/lab build el9 --ref v2.8.0 --patches patchsets/allow-idmap-v2.8.0
bin/lab build ubuntu 24.04 --ref v2.8.0 --patches patchsets/allow-idmap-v2.8.0

# на VM: RPM (локальный репозиторий, приоритет над официальным) или дерево /opt/daos
bin/lab deploy client-1 rpms @el9-v2.8.0-allow-idmap-v2.8.0
bin/lab deploy k8s-1 tree @el9-v2.8.0-allow-idmap-v2.8.0
bin/lab deploy client-1 release          # вернуть релизные пакеты

bin/lab test dfuse-idmap client-1
bin/lab test dfuse-idmap k8s-1 DAOS_PREFIX=/opt/daos
```

Бинарники для Ubuntu (tarball `/opt/daos`, как по QSG) проверяются в чистом контейнере Ubuntu на
client-VM. `--client` собирает только клиента и нужные ему зависимости (`scons client install`):
без сервера, SPDK, PMDK и тестовых программ. Такой архив подходит для клиентских узлов стенда.

К сборке для Ubuntu прикладывается то, из чего она собрана. Эти файлы лежат в
`<builds>/<имя>/out/source/` и в самом архиве, в `/opt/daos/share/daos/source/`:
- `SOURCE`: базовый коммит и список патчей;
- сами патчи в том виде, в каком применялись;
- `daos.diff`: всё изменение дерева сборки относительно базового коммита.

```bash
bin/lab build ubuntu 22.04 --ref 0dbc4ddda51cbb44bdc1aaa53913a10efc378397 \
    --patches patchsets/allow-idmap-master --client --name ubuntu-22.04-master-0dbc4dd-allow-idmap-client
bin/lab copy client-1 @ubuntu-22.04-master-0dbc4dd-allow-idmap-client
bin/lab test ubuntu-bin client-1 UBUNTU=22.04
```

Для Kubernetes:

```bash
bin/lab images push localhost/daos-client:el9-v2.8.0-allow-idmap-v2.8.0
bin/lab build csi localhost/daos-client:el9-v2.8.0-allow-idmap-v2.8.0 idmap-2.8.0
bin/lab csi k8s-1 @idmap-2.8.0                         # = <реестр лаборатории>/daos-csi:idmap-2.8.0
bin/lab test k8s-allow-idmap k8s-1 CLIENT_IMAGE=@el9-v2.8.0-allow-idmap-v2.8.0
```

Сборки идут на хосте в rootless podman. EL9 собирается примерно за час, при этом слои с
зависимостями кешируются. Результаты лежат в `<builds>/<имя>/out/`, и на них
ссылаются как на `@<имя>`. `<builds>` — это `$LAB_HOST_STORE/builds`.

## Команды

`bin/lab help` показывает полный список. Основные:

| Команда | Что делает |
|---------|------------|
| `status` | состояние и память VM, свободная память хоста, ядра, службы DAOS, пул |
| `start [vm...]`, `resume` | загрузить или восстановить VM и дождаться готовности |
| `stop [vm...]` | выключить VM (сервер теряет пул; `start` создаёт его заново) |
| `suspend [vm...]` | сохранить память VM на SSD и остановить |
| `use [группа\|vm...]` | оставить работать только эти VM |
| `kernel <vm> [stock\|ml]` | загрузить VM в стоковое ядро или в kernel-ml |
| `ssh <vm\|lab> [cmd]` | shell или команда на VM или хосте |
| `kubectl <vm> ...` | kubectl кластера на k8s- или talos-VM |
| `copy <vm> <путь\|@build> [dir]` | копирует файлы или tarball-ы сборки на VM |
| `deploy <vm> tests [пакеты]` | тестовые пакеты сборки (`daos-client-tests`: `dfuse_test`, ftest) |
| `test list`, `test [--keep] [--exclusive] <набор> <vm> [VAR=val]` | тесты; нужные VM поднимаются сами, см. [tests/README.md](tests/README.md) |

## Структура

| Путь | Что там |
|------|---------|
| `lab.conf` | все настройки: хост, VM, версии, DAOS, Kubernetes, Talos |
| `profiles/` | профили других лабораторий |
| `bin/lab` | CLI, работает на рабочей машине |
| `lib/` | `common.sh` (конфиг, ssh), `remote.sh` (общее для хоста и VM), `build.sh`, `csi.sh` |
| `host/` | скрипты, которые выполняются на libvirt-хосте: создание VM и Talos, питание VM (`vm-power.sh`), проверка |
| `nodes/` | настройка VM по ролям (от root, идемпотентно) |
| `talos/patches/` | патчи конфигурации Talos (шаблоны `@VAR@`) |
| `build/` | Containerfile сборок DAOS |
| `patchsets/` | наборы патчей DAOS для `lab build --patches` |
| `tests/` | тестовые наборы и их общая библиотека |
| `docs/gotchas.md` | грабли, на которые уже наступили |

## Безопасность

Лаборатория рассчитана на изолированную NAT-сеть:
- у DAOS отключён TLS (`allow_insecure`);
- реестр работает по HTTP;
- агент сопоставляет неизвестные uid с владельцем контейнера (`AGENT_DEFAULT_USER`).

Не используйте эти настройки там, где к сети есть посторонний доступ.
