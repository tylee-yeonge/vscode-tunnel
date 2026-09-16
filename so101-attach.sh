#!/bin/sh
# SO-ARM101 (LeRobot) 장치 노드를 컨테이너 /dev 에 생성한다. 팔과 카메라의 USB 를 꽂은 뒤 실행.
#
# 컨테이너 /dev 는 tmpfs 라 호스트 udev 가 만든 /dev/ttyACM*, /dev/video* 노드가 보이지 않는다.
# 대신 호스트와 공유되는 sysfs 에서 장치를 찾아 major:minor 를 읽고 mknod 로 고정 이름의
# 노드를 만든다. 접근 권한은 docker-compose.so101.yml 의 device_cgroup_rules
# (c 166:* 시리얼, c 81:* video4linux) 가 열어 둔다.
#   - 서보 보드: USB 시리얼 번호로 식별 (CH343 은 고유 시리얼을 가진다). 포트가 바뀌어도 된다.
#       SO101_FOLLOWER_SERIAL -> /dev/so101_follower
#       SO101_LEADER_SERIAL   -> /dev/so101_leader
#   - 카메라: 식별값이 USB 시리얼 번호 또는 USB 인터페이스 경로(예: 1-7.1:1.0) 어느 쪽과
#     같아도 잡는다. 시리얼로 적으면 보드처럼 포트가 바뀌어도 되지만, 웹캠 시리얼은 모델 공통값인
#     경우가 많아 같은 모델을 2대 쓰면 구분이 안 되므로 그때만 포트 경로로 적는다(같은 포트 전제).
#     UVC 카메라는 노드가 2개(index 0 캡처, index 1 메타데이터) 생기므로 index 0 만 잡는다.
#     변수가 비어 있으면 그 카메라는 건너뛴다.
#       SO101_CAM_WRIST_ID    -> /dev/so101_cam_wrist
#       SO101_CAM_OVERVIEW_ID -> /dev/so101_cam_overview
# 다시 꽂아 번호가 바뀌어도 재실행하면 노드를 새 번호로 갈아 끼운다.
# 장치가 안 보이면 남아 있던 노드를 지우고 실패(exit 1)한다.
# `so101-attach list` 는 현재 보이는 보드와 카메라를 .env 에 적을 값과 함께 출력만 한다.

# mknod_from_sysfs <노드 이름> <sysfs 장치 디렉터리>
mknod_from_sysfs() {
    devnum=$(cat "$2/dev")    # 예: 166:0
    rm -f "/dev/$1"
    mknod "/dev/$1" c "${devnum%%:*}" "${devnum##*:}"
    echo "[so101-attach] /dev/$1 -> $(basename "$2") ($devnum)"
}

# attach_tty <노드 이름> <USB 시리얼 번호>
attach_tty() {
    for tty in /sys/class/tty/ttyACM*; do
        [ -e "$tty" ] || continue
        # /sys/class/tty/ttyACMn/device 는 USB 인터페이스(예: 1-6.1:1.0)이고
        # 그 부모(1-6.1)가 USB 장치라 serial 속성을 가진다.
        [ "$(cat "$tty/device/../serial" 2>/dev/null)" = "$2" ] || continue
        mknod_from_sysfs "$1" "$tty"
        return 0
    done
    rm -f "/dev/$1"
    echo "[so101-attach] serial $2 not found in /sys/class/tty (USB unplugged?)" >&2
    return 1
}

# attach_video <노드 이름> <식별값: USB 시리얼 번호 또는 USB 인터페이스 경로>
attach_video() {
    for vid in /sys/class/video4linux/video*; do
        [ -e "$vid" ] || continue
        [ "$(cat "$vid/index")" = "0" ] || continue
        usbif=$(basename "$(readlink -f "$vid/device")")
        serial=$(cat "$vid/device/../serial" 2>/dev/null)
        [ "$serial" = "$2" ] || [ "$usbif" = "$2" ] || continue
        mknod_from_sysfs "$1" "$vid"
        return 0
    done
    rm -f "/dev/$1"
    echo "[so101-attach] camera $2 not found in /sys/class/video4linux (USB unplugged?)" >&2
    return 1
}

if [ "$1" = "list" ]; then
    echo "serial boards (value for SO101_FOLLOWER_SERIAL / SO101_LEADER_SERIAL):"
    for tty in /sys/class/tty/ttyACM*; do
        [ -e "$tty" ] || continue
        echo "  $(basename "$tty") serial=$(cat "$tty/device/../serial" 2>/dev/null)"
    done
    echo "cameras, capture nodes only (value for SO101_CAM_WRIST_ID / SO101_CAM_OVERVIEW_ID: serial or usb):"
    for vid in /sys/class/video4linux/video*; do
        [ -e "$vid" ] || continue
        [ "$(cat "$vid/index")" = "0" ] || continue
        echo "  $(basename "$vid") serial=$(cat "$vid/device/../serial" 2>/dev/null) usb=$(basename "$(readlink -f "$vid/device")") name=\"$(cat "$vid/name")\""
    done
    exit 0
fi

: "${SO101_FOLLOWER_SERIAL:?SO101_FOLLOWER_SERIAL is not set (.env)}"
: "${SO101_LEADER_SERIAL:?SO101_LEADER_SERIAL is not set (.env)}"

rc=0
attach_tty so101_follower "$SO101_FOLLOWER_SERIAL" || rc=1
attach_tty so101_leader "$SO101_LEADER_SERIAL" || rc=1
if [ -n "$SO101_CAM_WRIST_ID" ]; then
    attach_video so101_cam_wrist "$SO101_CAM_WRIST_ID" || rc=1
fi
if [ -n "$SO101_CAM_OVERVIEW_ID" ]; then
    attach_video so101_cam_overview "$SO101_CAM_OVERVIEW_ID" || rc=1
fi
exit $rc
