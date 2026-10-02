# Тесты

Каждый набор — это `tests/<набор>.sh`. `bin/lab test <набор> <vm> [VAR=value...]` копирует `tests/`
вместе с `lab.env` (настройки лаборатории) на VM и запускает его от root. Наборы для Kubernetes
с Talos-узлом запускаются на libvirt-хосте с kubeconfig кластера, потому что в Talos нет shell.
Результат — таблица `PASS/FAIL, ожидаемое, проверка`. Код возврата 1, если хотя бы одна проверка
не прошла.

```bash
bin/lab test list
bin/lab test smoke client-1
bin/lab test dfuse-idmap client-1 DAOS_PREFIX=/opt/daos
```

| Набор | Где | Что нужно |
|-------|-----|-----------|
| `smoke` | client, k8s | ничего, кроме выполненного `lab up` |
| `k8s-smoke` | k8s, talos | ничего, кроме выполненного `lab up` |
| `dfuse-idmap` | client, k8s | DAOS с патчем `patchsets/allow-idmap-*`, ядро `ml` (≥ 6.12) |
| `nlt` | k8s (12 GB RAM) | `lab deploy <vm> tree @<build>` и `lab deploy <vm> src @<build>` |
| `k8s-allow-idmap` | k8s, talos | `lab csi <vm> <image>` с образом CSI из сборки с патчем; `CLIENT_IMAGE=@<build>` |
| `ubuntu-bin` | client | `lab copy <vm> @<ubuntu build>`, `UBUNTU=22.04\|24.04` |
| `dfuse-unit` | client, k8s | `lab deploy <vm> tests` (`dfuse_test` из `daos-client-tests`) |
| `dfuse-client` | client | DAOS с патчем; systemd и SELinux, как на обычном клиенте |
| `podman-idmap` | client | DAOS с патчем, ядро `ml`; podman ставится сам |
| `k8s-multi-pod` | k8s, talos | как `k8s-allow-idmap` |
| `k8s-csi-resources` | k8s | `lab csi <vm> <image>` с образом csi-daos, где есть ресурсы mount-подов (`-r7` для всех проверок) |
| `k8s-csi-health` | k8s | `lab csi <vm> <image>` с образом csi-daos с проверками здоровья (`-r7` и новее) |
| `k8s-mlcore-csi` | k8s | Драйвер коллег (`mlcore.daos.csi`): `VARIANT=orig\|fixed IMAGE=<образ>`. Агент DAOS даёт `lab csi` |
| `k8s-rdma` | k8s в `profiles/rdma.conf` | провайдер verbs, `lab csi`; `CLIENT_IMAGE=@<build>` |
| `ftest` | ft-client (`profiles/ftest.conf`) | сборка и тестовые пакеты на обоих узлах профиля, см. ниже |

## Общие переменные

- `DAOS_PREFIX` задаёт, какую установку DAOS проверять. По умолчанию `/usr` (RPM). Для дерева из
  `lab deploy <vm> tree` нужно `/opt/daos`.
- Настройки лаборатории (`POOL`, `CONT`, `CONT_OWNER`, `SERVER_IP`, `REGISTRY`, …) берутся из
  `$LAB_ENV`. Список — в `lib/common.sh:write_env_file`.

## Как написать новый набор

1. Скопируйте `tests/smoke.sh`. Вторая строка файла — это описание, которое показывает
   `lab test list`. Третья — что набору нужно помимо VM, на которой он идёт: `# needs: server`
   (роли, группы или имена VM через пробел) или `# needs: none`. Без этой строки считается
   `server`. `lab test` поднимает недостающие VM и после прогона снова их приостанавливает.
2. `source lib/check.sh` даёт:
   - `check "<описание>" <ожидаемое> <фактическое>` — одна проверка;
   - `yes_no <команда>` — возвращает `yes`, если команда прошла;
   - `report "<заголовок>"` — выводит таблицу и задаёт код возврата;
   - `daos_paths` — выставляет `DAOS_BIN` и `DAOS_LIB` по `DAOS_PREFIX`;
   - `kernel_ge 6.12` — проверка версии ядра;
   - `tool <имя>` — путь к `tools/<имя>`, который собирается из `tools/<имя>.c` при первом вызове;
     `idmap_bind` — то же для `idmap-bind`.
3. Вспомогательные файлы кладите в `tests/tools/` (исходники, которые собираются на VM) и
   `tests/k8s/` (манифесты).
   Они копируются на VM вместе с набором.
4. Параметры передаются через переменные окружения: `lab test <набор> <vm> VAR=value`.
   Флаги `lab test` пишутся перед набором: `--keep` оставляет поднятые VM работать,
   `--exclusive` приостанавливает все VM, которые набору не нужны.

## Наборы

### smoke
Проверяет агент, доступ к пулу и контейнеру от владельца, монтирование dfuse и целостность
данных (запись и чтение `SIZE_MB`, по умолчанию 64 MiB). Проверяет чтение другим пользователем
через `--multi-user` и перехват ввода-вывода libioil и libpil4dfs.

### k8s-smoke
Проверяет узел Kubernetes без DAOS:
- узел в состоянии Ready;
- запускается обычный под;
- под с RuntimeClass `gvisor` работает под ядром gVisor;
- под с `hostUsers: false` получает user namespace.

Это основа для наборов, которые работают через `kubectl`.

### dfuse-idmap
Функциональные проверки `dfuse --allow-idmap`. Каждая проверка идёт дважды: dfuse без опции и с
ней.
- Создаётся idmapped bind mount (`tools/idmap-bind.c` делает то же, что runc для томов
  user-namespaced контейнеров).
- Проверяются сдвиг владельцев, создание файлов, права, chown, mkdir и rename через idmapped mount.
- Проверяется, кому dfuse отдаёт свои handles через ioctl. Их получает только пользователь dfuse,
  в том числе из вложенного pid namespace. Другой пользователь и вызовы из-за границы pid
  namespace dfuse их не получают.
- dfuse получает смонтированный `/dev/fuse` как `/dev/fd/N` (`tools/fuse-fd-mount.c` делает то же,
  что привилегированный помощник монтирования). С `--allow-idmap` handles не получает никто: pid
  вызывающих ядро тогда даёт в pid namespace помощника, а его dfuse проверить не может.

### nlt
Node local tests из дерева исходников DAOS, так же, как их запускает
`ci/unit/test_nlt_node.sh`: `NLT_ARGS='--test il_allow_idmap'` или весь набор.
`FORCE_IDMAP=1` запускает все dfuse набора с `--allow-idmap`. Прогон занимает около 1,5 часа и
поднимает свой сервер DAOS прямо на VM.

### k8s-allow-idmap
Сценарии из `k8s/allow-idmap.yaml`:
- поды с `hostUsers: false` и без него на томе csi-daos с `--allow-idmap`;
- владельцы, записанные в DAOS;
- libpil4dfs и libioil в поде;
- контрольный том без опции: user-namespaced под не стартует с ошибкой `MOUNT_ATTR_IDMAP`.

`KEEP=1` оставляет namespace для разбора.

### ubuntu-bin
Проверяет tarball `/opt/daos` из `lab build ubuntu` в чистом контейнере Ubuntu на client-VM:
- ставятся только runtime-пакеты;
- проверяется, что `ldd` не находит отсутствующих библиотек;
- запускается собственный `daos_agent` из tarball;
- затем запускается `dfuse-idmap`.

### dfuse-unit
`dfuse_test` (cmocka) из самого DAOS: так же, как его запускает ftest `daos_test/dfuse.py`
(`DaosCoreTestDfuse`). Этот тест upstream CI гоняет для изменений в dfuse.
- **Четыре режима кеша.** Для каждого (writeback, writethrough, metadata, otoc) создаётся свой
  контейнер с атрибутами этого режима.
- **Группы тестов** те же, что в ftest: io, stream, mmap, exec, directory, cache, path, lowfd,
  flock и metadata.
- **Варианты IL:**
  - без библиотеки перехвата;
  - `ioil`;
  - `pil4dfs`: handles берутся у dfuse через ioctl. Группы exec в этом варианте нет: её дочерний
    процесс требует `D_IL_MOUNT_POINT`;
  - `pil4dfs-env`: как в ftest, с `D_IL_MOUNT_POINT`, `D_IL_POOL` и `D_IL_CONTAINER`. С ними
    libpil4dfs подключается к пулу сам и ioctl dfuse не спрашивает.
- **Кто запускает.** dfuse и `dfuse_test` идут от одного пользователя: `AS` (по умолчанию владелец
  контейнера, можно `root`).
- **Режимы dfuse.** Всё повторяется для dfuse без опции и с `--allow-idmap` (`MODES`). Проверяется
  и то, что IL действительно берёт handles dfuse.
- **Точка монтирования** лежит в рабочем каталоге с правами 777: часть тестов path создаёт файлы
  рядом с тестовым каталогом.

### dfuse-client
То, что обычный клиент делает кроме тестов DAOS. Всё выполняется дважды: dfuse без опции и с
`--allow-idmap`.
- **dfuse пользователя в режиме демона.** Монтирует через `fusermount3`, размонтирует сам
  пользователь. libioil и libpil4dfs этого пользователя получают handles dfuse.
- **dfuse `--multi-user` как служба systemd** при SELinux enforcing, с `ExecStop=umount`.
- **Команды `daos filesystem query` и `evict`, `daos container query --path`,
  `daos filesystem get-attr --path`.** Они работают через ioctl dfuse. Проверяются от root и от
  другого пользователя.
- **libioil из второго потока.** dfuse видит TID вызывающего, а не PID, и с `--allow-idmap` читает
  `/proc/<pid>/task/<tid>`. Handles получает пользователь dfuse, другой пользователь — нет.

### podman-idmap
Несколько контейнеров podman (`--userns=auto`, каждый со своим диапазоном uid) на одном
монтировании dfuse, том подключается с опцией `idmap`.
- **Контроль.** Без `--allow-idmap` контейнер не стартует.
- **С опцией:**
  - файлы хранятся с теми владельцами, которые у них в контейнере;
  - контейнеры видят файлы друг друга с этими владельцами;
  - права между разными uid соблюдаются.
- **Без idmap** владельцем становится высокий uid хоста.

### k8s-multi-pod
Много подов на одном томе dfuse `--allow-idmap` (`k8s/multi-pod.yaml`). Поды только спят, а все
шаги по порядку выполняются через `kubectl exec`.
- **Поды на одном томе:**
  - 7 user-namespaced подов (uid 1000 и 2000, у каждого свой диапазон uid хоста);
  - поды без user namespace.
- **Данные и права.** Одновременная запись, целостность данных во всех подах, владельцы в DAOS и в
  подах, права между подами.
- **Владелец вне диапазона** user namespace виден как 65534.
- **Монтирования `subPath` и `readOnly`.**
- **IL параллельно в двух подах:** по 8 процессов libpil4dfs и 4 процесса libioil, в поде без user
  namespace и в поде с ним. dfuse должен различать каждого вызывающего.
- **Замена пода** во время чтения в соседнем.
- **Второй dfuse того же контейнера:** статический PV с тем же `volumeHandle`. Проверяется, что
  файлы видны через оба dfuse.

### k8s-csi-resources
Ресурсы dfuse в mount-подах csi-daos. Нагрузка — busybox `dd` через dfuse, IL не используется.
- **Настройки тома** (параметры StorageClass `dfuseCpu*`, `dfuseMemory*`) попадают в спецификацию
  mount-пода и в его cgroup: `cpu.max`, `memory.max`.
- **`--thread-count`** уменьшает число потоков dfuse.
- **Лимит CPU 200m** троттлит dfuse под нагрузкой. В выводе скорость записи с лимитом и без него.
- **Ошибочная настройка** (request больше limit) не даёт создать том, и в событии PVC назван
  параметр.
- **Request больше CPU узла:** kubelet отклоняет mount-под, драйвер удаляет его и пишет причину в
  событие пода.
- **Request, который помещается, только если выселить под с меньшим приоритетом.** kubelet
  выселяет «filler»-под ради mount-пода (`Preempting`). Это поведение kubelet для подов
  `system-node-critical`, его надо учитывать при выборе requests.
- **Значения по умолчанию из флагов плагина** (тест временно добавляет их в DaemonSet и потом
  откатывает его). Лимит без request получает request 0. Настройка тома перекрывает значение по
  умолчанию. Mount-поды, созданные раньше, сохраняют свои ресурсы после перезапуска плагина, и их
  тома работают.
- **Число потоков.** При лимите CPU драйвер добавляет `--thread-count` (лимит, округлённый вверх,
  плюс 1). `--thread-count` из `dfuseArgs` не трогается.
- **`-max-volumes-per-node`** = томов в работе + 1. CSINode показывает этот лимит. Под с ещё одним
  томом запускается, а под сверх лимита не планируется («max volume count»).

### k8s-csi-health
Проверки здоровья dfuse в csi-daos. Тест выполняется на самом узле: `kubectl`, `curl` метрик
плагина, `iptables`. На время теста плагину задаются короткие интервалы (проба каждые 3 с,
таймаут 5 с, убийство через 15 с), потом DaemonSet откатывается.

Два пода на одном томе: `plain` без liveness-пробы и `live` с пробой `stat -f /data`.
- **Здоровый том.** `daos_csi_volume_healthy` = 1, оба пода читают данные.
- **Ёмкость тома.** kubelet получает её через `NodeGetVolumeStats`, это видно по
  `kubelet_volume_stats_capacity_bytes`. Нужен `volumeStatsAggPeriod` > 0, см. `docs/gotchas.md`.
- **Замороженный dfuse (`SIGSTOP`):**
  - том нездоров, dfuse убит, mount-под поднимает новый;
  - mount'ы обоих подов переключены на новый dfuse;
  - `live` после перезапуска контейнера снова читает данные;
  - `plain` остаётся с мёртвым mount'ом.
- **Обрыв сети до сервера DAOS** (iptables DROP в обе стороны), как при отказе порта:
  - том нездоров, dfuse убит;
  - после возврата сети новый dfuse монтирует том, mount пода переключён, `live` читает снова.

### k8s-mlcore-csi
CSI-драйвер коллег (`DaosInmapPatch/colleagues-csi`) в тех случаях, где он ломался. Один и тот же
набор прогоняется на исходной версии (`VARIANT=orig`) и на исправленной (`VARIANT=fixed`).
Исходная версия часть проверок не проходит, так и задумано: это и есть найденные ошибки.
- **Манифесты** — их Helm chart, отрендеренный `helm template` (`k8s/mlcore/orig.yaml`,
  `fixed.yaml`).
- **Образы** — их Dockerfile на клиенте DAOS из сборки лаборатории. Внутренние библиотеки
  телеметрии и health заменены заглушкой `main.go`, логика CSI не тронута.
- **Тома** — статические PV на контейнере `mlcore-test`.

Проверки:
- **Поды на одном томе:** root с сокетом агента (libpil4dfs перехватывает), uid 1000 пишет,
  `hostUsers: false` (dfuse `--allow-idmap`). Поды стартуют без VolumeAttachment.
- **По 8 реплик на один том** стартуют и удаляются разом, 2 раунда: подов без mount'а нет,
  зависших при удалении нет.
- **Перезапуск пода драйвера:** работающий под читает том, новый под стартует.
- **Убитый dfuse тома:** новый под на этом томе стартует и читает.

### ftest
Функциональные тесты DAOS (avocado, `launch.py`) — так, как их гоняет upstream CI на VM.
- **Профиль `profiles/ftest.conf`:** две VM роли `ftest`. На ft-server харнесс сам поднимает
  сервер, ft-client запускает тесты и клиентов. Порядок команд — в шапке профиля.
- **По умолчанию** выполняются тесты, которые CI запускает для изменений dfuse на VM (теги `dfuse`
  и `vm`). Исключены `daos_build_vm` (многочасовая сборка DAOS на dfuse) и `ioctl_pool_handles`
  (2 сервера и ior). `TAGS` задаёт теги или файлы тестов.
- **`FORCE_IDMAP=1`** запускает каждый dfuse харнесса с `--allow-idmap`. Это правка
  `util/dfuse_utils.py`, которая действует только в лаборатории.
- **Результат.** Каждый тест avocado — отдельная проверка. Логи лежат в
  `~admin/avocado/job-results` на ft-client.

## Известные сбои

`tests/known-failures.txt`: тесты, которые падают не по вине проверяемого кода. Формат строки:
`<набор> <тест> <статус> <причина>`.
- **Как их показывает набор.** Сбой засчитывается как ожидаемый: PASS, ожидалось `FAIL`, в названии
  проверки — причина. Пока это делает `ftest`.
- **Если тест снова проходит,** в отчёте будет FAIL с «ожидалось FAIL, получено PASS». Тогда
  строку нужно убрать.
- **Подробности и доказательства** (сравнение со сборкой без патча) —
  `/Users/Dmitry/Documents/Claude/DaosInmapPatch/KNOWN-ISSUES.md`.

### k8s-rdma
Показывает, как поды добираются до DAOS по RDMA. Нужна лаборатория с провайдером verbs
(`profiles/rdma.conf`: Soft-RoCE, сборка с `patchsets/soft-rdma`).

Каждый под делает собственное подключение (`daos pool query`, как libpil4dfs и libioil) при
разном доступе к устройствам (privileged) и разной сети (сеть подов или `hostNetwork`).

Отдельные проверки:
- API-сервер отклоняет `hostUsers: false` вместе с `hostNetwork`;
- под с `hostUsers: false` пишет и читает 64 MiB через том dfuse с `--allow-idmap`. dfuse работает
  по verbs в mount-поде, так что для такого пода это единственный путь к DAOS по RDMA.
