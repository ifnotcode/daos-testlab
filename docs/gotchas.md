# Грабли

Всё, на что уже наступили при работе с лабораторией. Большая часть уже учтена в скриптах: там
указано, где именно. Остальное — поведение DAOS и Kubernetes, которое нужно помнить при
написании тестов.

## RDMA без железа (profiles/rdma.conf)

- **Программный RDMA.** У хоста нет RDMA-адаптеров, поэтому RDMA-лаборатория работает на
  программном RDMA поверх eth0 (`nodes/rdma.sh`, `DAOS_PROVIDER="ofi+verbs;ofi_rxm"`).
  - По умолчанию это Soft-RoCE (`rdma_rxe`), вместо него можно взять soft-iWARP (`siw`).
  - Оба модуля есть и в стоковом ядре EL9, и в kernel-ml.
  - Нужен `rdma-core`, а для memory registration — `memlock unlimited` для пользователей и для
    containerd, чей лимит наследуют поды.
  - Скорость около 1 Гбит/с при задержке порядка 60 мкс: это проверка того, что всё работает,
    а не измерение производительности.
- **DAOS не видит программные RDMA-устройства.** Control plane учитывает только устройства с
  PCI-устройством за ними, то есть со ссылкой `/sys/class/infiniband/<dev>/device`. У `rxe0`
  и `siw0` её нет, есть только файл `parent`.
  - Без исправления `daos_server` падает с `no fabric interfaces found with provider`, агент
    ведёт себя так же.
  - Исправление — `patchsets/soft-rdma`: 30 строк в `src/control/lib/hardware/sysfs/provider.go`
    с unit-тестом, ветка `lab-soft-rdma` в клоне DAOS проекта патча. Оно нужно только
    лаборатории, в PR про idmap не входит.
  - Поэтому RDMA-лаборатория целиком ставит сборку с этим патчем (`DAOS_BUILD` в профиле).
- **CQ у rxe маленькие.** Soft-RoCE допускает не больше 32767 записей в CQ (`max_cqe`).
  - rxm определяет размер CQ через `FI_UNIVERSE_SIZE`, а CaRT по умолчанию ставит 2048. Тогда
    endpoint не открывается: `Unable to create verbs CQ`, `fi_enable() ... -22`.
  - `nodes/daos-server.sh` при программном RDMA задаёт `FI_UNIVERSE_SIZE=64` движку, а клиентам
    передаёт через `client_env_vars` сервера: агент отдаёт его вместе с attach info.
- **RPC движка самому себе не проходят.** Клиенты работают, в том числе на самом сервере, но
  RPC движка к самому себе (rank 0 → rank 0) по verbs/rxm на rxe зависает.
  - Поэтому `dmg pool list` и `dmg pool query` висят 5 минут и заканчиваются `DER_TIMEDOUT`.
  - `daos pool query` с клиента работает.
- **CSI при RDMA: агенту и контроллеру тоже нужны RDMA-устройства.** Для verbs доступ к
  `/dev/infiniband` нужен не только dfuse в mount-подах, которые и так privileged.
  - Агенту (DaemonSet): его fabric scan через mercury без устройств падает с
    `crt_hg_get_protocol_info: DER_HG_FATAL`, и клиенты получают `GetAttachInfo unsuccessful`.
  - Контроллеру: его `daos container create` без устройств падает с `DER_MISC`, и PVC висят в
    Pending.
  - В манифестах драйвера оба пода непривилегированные, для tcp этого достаточно.
    `lib/csi.sh` при verbs делает их privileged. В реальном кластере вместо этого подойдёт
    device plugin для RDMA.

## Хост и VM

- **Только ssh-ключ, без sudo на хосте.** Пользователь хоста состоит в группе `libvirt`, поэтому
  всё делается через `virsh -c qemu:///system`, `virt-install` и rootless podman. Если чего-то не
  хватает, `lab check` покажет, что должен поправить администратор.
- **rootless podman умирает вместе с ssh-сессией.** Когда закрывается последняя ssh-сессия
  пользователя хоста, systemd завершает его контейнеры, включая долгие сборки. Поэтому
  `lib/build.sh` держит сессию открытой на всё время `podman build`.
  - По этой же причине реестр образов работает на server-VM под systemd (quadlet), а не на хосте.
- **Место в пуле libvirt.** Диски VM — тонкие qcow2-overlay. Когда место кончается, VM
  становятся на паузу. Команда `lab check` показывает свободное место.
  - На хосте 192.168.1.83 стандартный пул `images` лежит на корневой ФС, где свободно около
    6 GB. Сервер с клиентом занимают около 5 GB, узел k8s — около 3 GB.
  - Поэтому пул `testlab`, сборки и кеш загрузок лежат на внешнем SSD `/mnt/keenetic`
    (`LAB_HOST_STORE`): Samsung T7, USB, ext4, около 650 MB/s.
    - У каталогов там SELinux-метка `container_file_t`. qemu это не мешает: при запуске VM
      libvirt сам ставит файлам дисков `svirt_image_t`, а базовым образам `virt_content_t`.
    - Диск монтируется из fstab. Если его нет, `lab check` сообщит об этом.
- **Кеш загрузок** (`$LAB_HOST_STORE/cache`) хранит облачные образы AlmaLinux, образы Talos,
  talosctl и kubectl. При пересоздании лаборатории они не скачиваются заново и не зависят от
  изменений в интернете.
  - Чтобы получить свежий образ `latest`, удалите файл из `cache/images`.
  - Всё, что VM один раз скачала и потом удалила, остаётся занятым в qcow2. Поэтому диски
    создаются с `discard=unmap`, а после `provision` выполняется `dnf clean all` и `fstrim -a`.
    Кроме того, включён `fstrim.timer`.
  - DAOS bdev — AIO-файл, выделенный через fallocate. Место в qcow2 он почти не занимает, пока
    туда не пишут.
- **podman и `/var/tmp`.** Слои при `podman build` проходят через `$TMPDIR` (по умолчанию
  `/var/tmp`, на маленькой корневой ФС). Слой Ubuntu-сборки туда не помещался, поэтому команды
  podman на хосте идут через `host_podman` с `TMPDIR=<builds>/.tmp`.
  - Хранилище образов podman осталось в `/home`, там около 70 GB свободно.
- **Новый ключ хоста.** У пересозданной VM другой ssh host key. `lab destroy` и `lab create`
  убирают старый ключ из `work/<lab>/known_hosts`.
- **bash 3.2 на рабочей машине (macOS).** В `bin/lab` и `lib/common.sh` нельзя использовать
  `mapfile`, ассоциативные массивы и пустые массивы при `set -u`. Скрипты на VM и хосте работают
  в bash 5.
- **Правка `bin/lab` во время работы** ломала запущенную команду: bash читает скрипт по ходу
  выполнения. Теперь всё выполняется из функции `main`, и файл читается целиком до старта.
- **`vol-upload` в qcow2-том** может показывать устаревшую allocation. После загрузки нужен
  `pool-refresh` (есть в `host/create-vm.sh`). VM на пустой базе висит без DHCP-аренды.
- **cloud-init и `/etc/hosts`.** По умолчанию cloud-init сопоставляет имя хоста с 127.0.0.1, и
  тогда `daos_server` и kubeadm слушают loopback. Поэтому используются `manage_etc_hosts: false`
  и статический `/etc/hosts` из `VMS` (`lib/remote.sh:hosts_file`).
- **AlmaLinux 9.7.** Облачный образ из vault при первом `dnf update` уходит на 9.x latest. Для
  образа `alma9.7` cloud-init переключает репозитории на `vault.almalinux.org/9.7`.
- **ELRepo** иногда отвечает таймаутом, поэтому `nodes/kernel-ml.sh` повторяет попытки.
  kernel-ml ставится ядром по умолчанию, а стоковое остаётся установленным.
- **`pkill -f` через ssh** убивает саму ssh-сессию, если шаблон входит в командную строку.
  Процессы нужно завершать по PID.

- **Память хоста.** Все VM сразу почти не помещаются в 31 GB. Раньше VM стартовали вместе с
  хостом и держали всю память, которую однажды заняли: k8s-1 после NLT держал 11 GB. Теперь
  автозапуска нет, а free page reporting (virtio-balloon) возвращает хосту память, которую
  освободил гость. `lab status` показывает, сколько занимает каждая VM.
- **managedsave пишет на корневую ФС** (`/var/lib/libvirt/qemu/save`), а там мало места. Сменить
  этот каталог без root нельзя. Поэтому `lab suspend` использует `virsh save` в
  `$LAB_HOST_STORE/saved`.
  - Такой образ libvirt не отслеживает. Если VM загрузили мимо `lab start` (`virsh start`,
    автозапуск), образ устарел: восстанавливать его нельзя, диск уже другой.
    `host/vm-power.sh` сверяет mtime и размер дисков с отметкой, сделанной при сохранении, и
    удаляет устаревший образ.
- **Часы после восстановления** показывают время сохранения. chrony (`makestep 1.0 3`) правит
  время скачком только сразу после загрузки, а дальше медленно подгоняет. Поэтому `lab start`
  выставляет часы через qemu-guest-agent (`virsh domtime --sync`). У Talos агента нет, и
  `lab suspend` его просто выключает.
- **Восстановленная VM берёт XML домена из образа.** Изменения в конфигурации домена, например
  free page reporting, вступают в силу только после холодного старта (`lab stop`, `lab start`).
- **`kubectl wait` сразу падает**, пока API-сервер после загрузки узла не отвечает. Готовность
  узла нужно опрашивать в цикле (`node_ready` в `bin/lab`).
- **Узел Ready — ещё не кластер.** После холодной загрузки узел быстро становится Ready, а
  control plane (kube-apiserver, controller-manager, scheduler) через минуту-две перезапускается.
  Если в этот момент создать namespace, в нём не появляется ServiceAccount `default`, и поды
  отклоняются с `serviceaccount "default" not found`. Поэтому `node_ready` ждёт, чтобы поды
  kube-system и daos-csi дважды подряд, с паузой 20 секунд, были Ready.
  - Поды, которые узел остановил при выключении, остаются в состоянии Failed и никогда не станут
    Ready. `node_ready` их удаляет.
- **virtqemud запускается по сокету и сам завершается после простоя** (`--timeout 120`). Если
  попасть в этот момент, вызов `virsh` не получает ответа. `vm-power.sh` повторяет
  `virsh domstate` несколько раз и только потом считает домен отсутствующим.
- **podman на ядре kernel-ml:** сеть по умолчанию (bridge через iptables-legacy) не поднимается, в
  ядре нет таблицы `nat`. Тестовым контейнерам сеть не нужна: `--network none`.
- **`GROUPS` — встроенная переменная bash** (группы текущего пользователя): присваивание ей
  молча игнорируется. Поэтому группы VM называются `VM_GROUPS`.
- **tar из macOS** пишет в архив флаги файлов (`SCHILY.fflags`), и GNU tar на хосте и VM
  предупреждает о них. `push_files` передаёт bsdtar `--no-fflags`.

## DAOS

- **Память сервера.** DAOS 2.8 не стартует, если SCM (класс ram) меньше 4 GiB, и если
  `MemTotal − system_ram_reserved − hugepages − 1 GiB < SCM`. По умолчанию hugepages берутся по
  512 (1 GiB) на target.
  - При 2 targets этого мало: engine падает с `Failed to grow DMA buffer` и `DER_NOMEM`. Для
    маленького сервера нужны `DAOS_HUGEPAGES=1536` и `DAOS_RAM_RESERVED_GB=1`
    (`profiles/verify.conf`, VM 10 GB).
  - `nodes/daos-server.sh` сразу показывает ошибку из лога `daos_server`/engine вместо долгого
    ожидания.
- **Перезагрузка server-VM стирает DAOS.** SCM лежит в tmpfs, поэтому после перезагрузки система
  «uninitialized», и пула нет. `lab provision <server>` форматирует систему и заново создаёт пул,
  контейнер и ACL. `lab start` после холодной загрузки сервера делает это сам.
  - На клиентах после этого нужно перемонтировать dfuse. `lab start` перезапускает агентов на
    работающих клиентах, `lab provision <client>` тоже перезапускает агент.
  - `lab suspend` сохраняет сервер вместе с пулом: tmpfs уходит в образ памяти.
- **Повторный `provision` сервера** должен быть безопасным. `dmg storage format` на работающей
  системе возвращает «invoked on a running system», поэтому форматирование пропускается, если
  engine уже Joined.
  - `daos_server` перезапускается только при изменении `daos_server.yml`, иначе handles всех
    клиентов пропадут.
- **THP и libaio.** `daos_engine` требует `transparent_hugepage=never`: это аргумент ядра и
  перезагрузка, скрипт выходит с кодом 100, `lab` перезагружает VM и запускает его снова. RPM 2.8
  не тянут `libaio`, без неё engine не стартует.
- **ACL.** Записи `EVERYONE@` нет. Пул и контейнер принадлежат `CONT_OWNER`. dfuse на клиентах
  работает от root, поэтому `root@` добавлен явно (`POOL_ACL_EXTRA`, `CONT_ACL_EXTRA`).
  - Корень контейнера принадлежит uid владельца (1000), а не root.
- **`client_user_map.default`.** Процессы с uid без записи в passwd (поды с user namespace)
  приходят в агент со случайными uid хоста. Агент сопоставляет их с `AGENT_DEFAULT_USER`: сейчас
  это владелец контейнера, то есть полные права.
  - Это ограничение самого DAOS: ACL не различают такие поды.
- **Агент и интерфейсы.** Агенту везде нужен `include_fabric_ifaces: [eth0]`. Без этого он по
  очереди раздаёт клиентам все интерфейсы, и каждый второй вызов получает `DER_TIMEDOUT`.
  - На узлах Kubernetes это `flannel.1` и `cni0`.
  - На сервере это `podman0` реестра. Он появляется только после первого `provision`, поэтому
    ошибка видна лишь при повторном запуске.
- **Перезапуск `daos_agent`** вытесняет все локальные handles, включая handles dfuse.
  Смонтированные dfuse нужно перемонтировать, иначе будет `DER_NO_HDL`.
  - Поэтому `nodes/deploy-rpms.sh` перезапускает агент только там, где он включён.
- **Без NAT между клиентом и сервером.** mercury `ofi+tcp` отвечает на адрес, который объявил
  клиент, а у пода это pod IP. MASQUERADE от flannel это ломает.
  - На k8s-узле `daos-pod-nonat.service` исключает трафик pod→storage из masquerade.
  - На server-VM добавлены маршруты в pod-сети через узлы (`lib/remote.sh:pod_routes`).
  - Для Talos у flannel включён `--ip-masq=false`.
- **`dmg` на сервере** запускается с `-o /etc/daos/daos_control.yml`, как в скриптах лаборатории.
- **Локальный RPM-репозиторий** (`lab deploy rpms`) имеет `priority=1`. Без этого побеждает
  libfabric 2.x из AppStream, а сборке DAOS нужна версия из её собственных deps.
  - Скрипты RPM при замене пакетов останавливают и выключают `daos_agent`. `deploy-rpms.sh`
    запоминает его состояние до замены.
  - Сборка режет пакеты иначе, чем релиз: например, `isa-l` + `libisa-l` против одного `isa-l`
    из EPEL. Поэтому возврат к релизу (`deploy release`) делает `distro-sync --allowerasing` и
    удаляет пакеты сборки, которых нет ни в одном репозитории.
  - Файл локального репозитория удаляется последним, чтобы неудачный запуск можно было
    повторить.
- **Дерево `/opt/daos` без зависимостей.** Tarball из `scons install` не тянет системные
  библиотеки, которые ставят RPM: `libunwind` (без неё не стартует `daos_engine` в NLT),
  `libndctl`, `libdaxctl`, `libcmocka`, `libhdf5`. `lab deploy <vm> tree`
  (`nodes/deploy-tree.sh`) находит недостающие через `ldd` и ставит их по soname
  (`dnf install '<soname>()(64bit)'`).
  - Если NLT падает с `error while loading shared libraries`, дерево поставлено не через
    `lab deploy`.
  - Когда NLT падает, его `daos_server` остаётся работать и держит ssh-сессию `lab test`.
    `tests/nlt.sh` после завершения NLT сам останавливает такие процессы.
- **RUNPATH `/opt/daos`.** В RPM из `utils/build` у NA-плагинов mercury прописан абсолютный
  RUNPATH `/opt/daos/...`. Если на той же VM есть дерево `/opt/daos` другой версии, плагины
  подхватят библиотеки оттуда.
- **Prereq builder DAOS** не пересобирает компонент, если его версия в `utils/build.config`
  поменялась, но каталог сборки уже есть. `lab build` каждый раз начинает с чистого клона, так
  что это важно только при ручной сборке.

## dfuse и перехват ввода-вывода

- **dfuse `--foreground`** нужен, чтобы `D_LOG_FILE` продолжал писаться: демонизированный потомок
  перестаёт писать в лог.
- **Остановка dfuse.** SELinux не даёт systemd-сервису выполнить `fusermount3`: ExecStop падает с
  203/EXEC, и остаётся stale mount. В юнитах нужно использовать `ExecStop=/usr/bin/umount <dir>`.
  - `systemctl stop` без ExecStop тоже оставляет stale mount.
- **DFS не поддерживает sticky bit.** `chmod 1777` и `rootMode: 1777` в CSI дают ENOTSUP.
- **`-o` в dfuse обрезается.** `parse_mount_option()` (master и 2.8) останавливается после первой
  распознанной опции `-o`. Из-за этого `mount -t fuse3 ... -o pool=P,container=C` монтирует весь
  пул. Это существующая ошибка DAOS. Надёжно работают только аргументы командной строки.
- **libioil скрывает отказ.** Если dfuse не отдаёт свои handles, libioil «backs off» и
  подключается сам с правами вызывающего. Счётчики чтений поэтому ничего не доказывают: нужно
  искать в DEBUG-логе `ioctl returned` или `backing off` (`tests/dfuse-idmap.sh:ioil_handles`).
  - У libpil4dfs такого запасного пути нет: при отказе `op_sum` равен 0.
- **Итог libioil пишется из деструктора** и может потеряться в stderr. Надёжнее читать
  `D_LOG_FILE` с `D_LOG_MASK=DEBUG DD_MASK=all`.
- **`LD_PRELOAD` перед `unshare`/`nsenter`** загружает IL и в обёртку, и её итог затирает лог.
  Обёртка должна идти первой, а `env LD_PRELOAD=...` — после неё.
- **libpil4dfs по умолчанию пропускает** некоторые команды (например `cat`). Для тестов нужен
  `D_IL_NO_BYPASS=1`.
- **dfuse в pid namespace с чужим `/proc`** падает в hwloc с `DER_MISC`, если не задан
  `--thread-count`.
- **Idmapped mounts (FUSE).** Нужны Linux ≥ 6.12 и `FUSE_ALLOW_IDMAP` от демона. После этого ядро
  присылает uid/gid -1 во всех запросах, кроме создающих inode.
  - Именно поэтому патч читает fsuid/fsgid вызывающего из `/proc/<pid>/status`.
  - pid вызывающего ядро даёт в pid namespace того процесса, который смонтировал ФС. Если dfuse
    получает уже смонтированный `/dev/fuse` как `/dev/fd/N`, это может быть чужой namespace.
    Поэтому с `--allow-idmap` такой dfuse не отдаёт handles никому (`tools/fuse-fd-mount.c`).

- **`dfuse_test` (cmocka) и окружение.**
  - Тесты path (`do_root_symlink_up`, `do_symlink_dot_dot_value`) создают файл в каталоге над
    `--test-dir`, поэтому родительский каталог точки монтирования должен быть доступен на запись
    пользователю теста. Каталог `/mnt` не подходит.
  - `do_exec` с libpil4dfs проверяет в дочернем процессе, что задан `D_IL_MOUNT_POINT`.
- **libpil4dfs с `D_IL_POOL` и `D_IL_CONTAINER`** подключается к пулу сам (`init_dfs()`) и
  ioctl dfuse не вызывает. Путь `--allow-idmap` проверяется только без этих переменных.
- **Special test NLT `run_dfuse`** запускает dfuse через `numactl`. Без него NLT падает в конце и
  не выполняет оставшиеся части. `tests/nlt.sh` ставит `numactl` сам.

## ftest (avocado)

Известные сбои тестов, которые не связаны с проверяемым кодом, перечислены в
`tests/known-failures.txt`. Подробности и доказательства — в
`/Users/Dmitry/Documents/Claude/DaosInmapPatch/KNOWN-ISSUES.md`.

- **`daos-client-tests` требует `ior`,** а его нет ни в одном подключённом репозитории.
  `lab deploy <vm> tests` ставит пакет через `rpm --nodeps` и перечисляет, чего не хватило.
- **pydaos собирается из C:** нужны `libuuid-devel` и `boost-devel` (расширение torch).
- **Движок с N targets требует N + 2 ядер.** Иначе в логе движка: «cannot start engine with 4
  targets 0 xs_helpers on 4 cores», а харнесс ждёт 40 секунд и сообщает только «Failed to start
  servers after format». Поэтому у ft-server 8 vCPU.
- **Фильтр по тегам `dfuse,vm`** захватывает и тесты `datamover` и `pytorch`. Одному из них нужны
  2 сервера, и `launch.py` отказывается запускать весь набор («Not enough 'test_servers'
  placeholder replacements»). Поэтому `tests/ftest.sh` по умолчанию передаёт список файлов.
- **Харнесс сам останавливает и выключает** `daos_server.service` на серверах и пишет свою
  конфигурацию в `/var/tmp/daos_testing`. Поэтому на узлах ftest нет сервера и агента
  лаборатории.
- **`virt-xml --edit`** принимает только одно изменение за вызов: vCPU и память меняются двумя
  вызовами.
- **Инструменты тестов `dfuse/bash.py`:** `xxd` (пакет `vim-common`), `valgrind`, `dos2unix`,
  `bzip2`, `objdump`. Без них тесты падают на первой же отсутствующей команде.
- **`verify_perms.py` (`dfuse/mu_perms.py`)** перебирает права сотнями запусков через sudo. Его
  таймаут 240 секунд зашит в `util/dfuse_utils.py`, и `--timeout_multiplier` его не меняет. На
  клиенте с 2 vCPU шаг «real» не укладывается в это время, поэтому у ft-client 6 vCPU.
- **`test_bashfd_pil4dfs` падает и в upstream** (проверено на master `0dbc4dd` без патчей, на ядрах
  5.14 и 7.2): `bash_fd_inner.sh: xrealloc: cannot allocate 4294967464 bytes`. libpil4dfs выдаёт
  фиктивные fd около `0x20000000`, а bash 5.1.8 заводит таблицу буферов по номеру fd:
  (0x20000014 + 1) × 8 байт. Воспроизводится без avocado: скрипты теста в корне монтирования,
  `LD_PRELOAD=libpil4dfs.so D_IL_NO_BYPASS=1`.

## Kubernetes и Talos

- **`kubectl ... | grep -q` в тестах с `set -o pipefail`.** grep выходит на первом совпадении,
  kubectl получает SIGPIPE, и весь конвейер считается неудачным, хотя строка найдена. С большим
  выводом (метрики kubelet) так бывает всегда. Сначала сохранить вывод в переменную, потом
  `grep -q ... <<<"$out"`.
- **Статистика томов в kubeadm выключена.** kubeadm пишет в `/var/lib/kubelet/config.yaml`
  `volumeStatsAggPeriod: 0s`, и kubelet не вызывает `NodeGetVolumeStats`: метрик
  `kubelet_volume_stats_*` нет. `nodes/k8s.sh` ставит 1m (и исправляет существующие кластеры).
- **Mount-поды csi-daos с requests выселяют чужие поды.** Mount-поды создаются с `nodeName`,
  мимо планировщика, и имеют приоритет `system-node-critical`. Если их requests не помещаются,
  kubelet выселяет поды с меньшим приоритетом («Preempted in order to admit critical pod»). Если
  не помогает и это, mount-под отклоняется с `UnexpectedAdmissionError`. Проверяет
  `k8s-csi-resources`.
- **`getsubids`.** Поддержке user namespaces в kubelet нужен `shadow-utils-subid` и диапазон
  subuid/subgid для пользователя `kubelet` (`nodes/k8s.sh`).
- **gVisor с 2026-09** выпускается одним архивом `gvisor.tar.bz2`. Прежние URL `runsc` и
  `containerd-shim-runsc-v1` отдают 404.
  - `runsc` требует рядом каталог `gvisor-bin/` с sidecar-процессами (`gvisor_sentry`), иначе
    пишет «sidecar not usable».
  - `GVISOR_RELEASE` закреплён на дате релиза: с `latest` установка может сломаться в любой
    момент.
- **flannel** из `kube-flannel.yml` жёстко задаёт 10.244.0.0/16. Для другого `K8S_POD_CIDR`
  `k8s.sh` подставляет его в манифест.
- **sudo `secure_path`** не содержит `/usr/local/bin`, где лежат containerd и runc. Для ручных
  `crictl` и `ctr` нужны полные пути.
- **Talos v1.14.**
  - Сетевые настройки и taints задаются новыми документами (`KubeNetworkConfig`,
    `KubeFlannelCNIConfig`, `KubeNodeConfig`), а не полями `cluster:`.
  - Список `podSubnets` в patch заменяется целиком.
  - Taint control-plane удаляется только через `taints: {$patch: delete}`: удалить отдельный
    ключ нельзя, потому что в нём есть точки.
  - `diskSelector` задаётся в `UnattendedInstallConfig.provisioning`.
  - Legacy- и новые документы в одном patch-файле допустимы, если разделены `---`.
  - `.machine.files` выдаёт предупреждение «deprecated». В следующих версиях Talos его нужно
    будет заменить отдельными документами.
  - Расширение gvisor только добавляет runtime `runsc` в containerd. RuntimeClass `gvisor`
    создаёт `create-talos.sh`.
  - Talos API отвечает раньше, чем узел регистрируется в Kubernetes. Перед `kubectl wait` нужно
    дождаться появления объекта Node.
- **Секреты Talos** (`$HOST_WORK/talos/<vm>/secrets.yaml`) создаются один раз и дальше
  переиспользуются. После потери этого файла кластер нужно создавать заново, а не
  переконфигурировать.
  - Секреты существующего кластера можно извлечь командой
    `talosctl gen secrets --from-controlplane-config controlplane.yaml`. Так talos-1 основной
    лаборатории, созданный ещё старыми скриптами, подключён к `bin/lab`.
- **CSI mount pods нужен `hostPID`,** иначе dfuse не видит pid вызывающих при `--allow-idmap`.
