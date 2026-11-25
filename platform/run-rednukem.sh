#!/bin/sh

# Keep this before every function, command substitution, and environment
# lookup so an empty direct invocation cannot reach Rednukem.
if [ "$#" -eq 0 ]; then
    printf 'Refusing to launch Rednukem without arguments.\n' >&2
    printf 'Usage: %s [--launcher [--debug | --debug-log /path/to/log] --] <Rednukem argument> [Rednukem arguments...]\n' "$0" >&2
    exit 64
fi

usage() {
    printf 'Usage: %s [--launcher [--debug | --debug-log /path/to/log] --] <Rednukem argument> [Rednukem arguments...]\n' "$0" >&2
}

debug=0
debug_log=${REDNUKEM_GSG_DEBUG_LOG:-}
if [ -n "${REDNUKEM_GSG_DEBUG:-}" ] && [ "${REDNUKEM_GSG_DEBUG}" != 0 ]; then
    debug=1
fi

if [ "${1:-}" = "--launcher" ]; then
    shift
    launcher_delimiter=0

    while [ "$#" -gt 0 ]; do
        case $1 in
            --debug)
                debug=1
                shift
                ;;
            --debug-log)
                if [ "$#" -lt 2 ]; then
                    usage
                    exit 64
                fi
                debug=1
                debug_log=$2
                shift 2
                ;;
            --)
                shift
                launcher_delimiter=1
                break
                ;;
            *)
                usage
                exit 64
                ;;
        esac
    done

    if [ "$launcher_delimiter" -ne 1 ]; then
        usage
        exit 64
    fi
fi

if [ "$#" -eq 0 ]; then
    printf 'Refusing to launch Rednukem without arguments.\n' >&2
    usage
    exit 64
fi

game_dir=
expect_game_dir=0
for argument do
    if [ "$expect_game_dir" -eq 1 ]; then
        game_dir=$argument
        expect_game_dir=0
        continue
    fi

    if [ "$argument" = "-game_dir" ]; then
        expect_game_dir=1
    fi
done

# The launcher may run from /mnt/sdcard even when EmulationStation supplies
# a /sdcard path. Use the application-visible mount only when it exists.
case $game_dir in
    /sdcard/*)
        mounted_game_dir=/mnt$game_dir
        if [ -d "$mounted_game_dir" ]; then
            set -- "$@" -game_dir "$mounted_game_dir"
            game_dir=$mounted_game_dir
        fi
        ;;
esac

force_ww2gi=0
gamegrp=
expect_gamegrp=0
for argument do
    if [ "$expect_gamegrp" -eq 1 ]; then
        gamegrp=$argument
        gamegrp_basename=${argument##*/}
        gamegrp_basename=${gamegrp_basename##*\\}
        case $gamegrp_basename in
            [Ww][Ww]2[Gg][Ii].[Gg][Rr][Pp])
                force_ww2gi=1
                ;;
        esac
        expect_gamegrp=0
        continue
    fi

    if [ "$argument" = "-gamegrp" ]; then
        expect_gamegrp=1
    fi
done

if [ "$force_ww2gi" -eq 1 ]; then
    # Some legitimate WWII GI archive revisions are not in the fixed
    # CRC/size scanner table.  The explicit main archive name is authoritative.
    set -- "$@" -ww2gi
fi

if [ -n "$game_dir" ] && [ -n "$gamegrp" ]; then
    case $gamegrp in
        /*)
            gamegrp_path=$gamegrp
            ;;
        *)
            gamegrp_path=$game_dir/$gamegrp
            ;;
    esac

    if [ ! -f "$gamegrp_path" ] || [ ! -r "$gamegrp_path" ]; then
        printf 'Cannot read main game archive: %s\n' "$gamegrp_path" >&2
        if [ -d "$game_dir" ]; then
            printf 'Game-data directory contents (%s):\n' "$game_dir" >&2
            if ! ls -la "$game_dir" >&2; then
                printf 'Cannot list game-data directory: %s\n' "$game_dir" >&2
            fi
        else
            printf 'Game-data directory is unavailable: %s\n' "$game_dir" >&2
        fi
        exit 66
    fi
fi

package_dir=$(CDPATH= cd "$(dirname "$0")" && pwd) || {
    printf 'Cannot resolve package directory: %s\n' "$(dirname "$0")" >&2
    exit 70
}

executable=$package_dir/rednukem
lib_dir=$package_dir/lib
controller_config_file=$package_dir/gamecontrollerdb.txt

# Debug capture without editing menu entries: if this file exists, write an
# input/debug log next to it on every launch. Delete the file to disable.
debug_flag_file=$package_dir/gsg-debug
if [ -f "$debug_flag_file" ]; then
    debug=1
    debug_log=${debug_log:-$package_dir/gsg-input.log}
fi

# HDMI: reset the external connector exactly like the vendor's RetroArch
# launcher, route audio to HDMI, and select the external display (SDL display
# 1 with the bundled SDL2; the engine's direct-DRM presenter finds the
# connector itself either way).
for connector in /sys/class/drm/card*-HDMI-* /sys/class/drm/card*-DP-* \
    /sys/class/drm/card*-DisplayPort-* /sys/class/drm/card*-DVI-* \
    /sys/class/drm/card*-VGA-*; do
    if [ -r "$connector/status" ] && [ "$(cat "$connector/status")" = connected ]; then
        printf 'External display detected at %s; selecting SDL display 1\n' "$connector" >&2
        EDUKE32_GSG_DISPLAY_INDEX=${EDUKE32_GSG_DISPLAY_INDEX:-1}
        export EDUKE32_GSG_DISPLAY_INDEX
        if ! {
            printf off >"$connector/status"
            printf on >"$connector/status"
            printf detect >"$connector/status"
        }; then
            printf 'Warning: could not reset external display connector %s\n' "$connector" >&2
        fi
        AUDIODEV=hdmi
        export AUDIODEV
        if command -v alsactl >/dev/null 2>&1 && [ -r /sdcard/asound.state ]; then
            alsactl restore -f /sdcard/asound.state >/dev/null 2>&1 \
                || printf 'Warning: alsactl restore failed\n' >&2
        fi
        ALSA_CARD=0
        ALSA_DEVICE=1
        export ALSA_CARD ALSA_DEVICE
        # Full-resolution software rendering is too heavy at 1920x1080 on this
        # SoC; render at half resolution and upscale on present.
        EDUKE32_GSG_UPSCALE=${EDUKE32_GSG_UPSCALE:-2}
        export EDUKE32_GSG_UPSCALE
        break
    fi
done

if [ ! -x "$executable" ]; then
    printf 'Cannot execute Rednukem binary: %s\n' "$executable" >&2
    exit 70
fi

if [ ! -d "$lib_dir" ]; then
    printf 'Cannot find package library directory: %s\n' "$lib_dir" >&2
    exit 70
fi

if [ -n "${LD_LIBRARY_PATH:-}" ]; then
    LD_LIBRARY_PATH=$lib_dir:$LD_LIBRARY_PATH
else
    LD_LIBRARY_PATH=$lib_dir
fi
export LD_LIBRARY_PATH

# Rednukem also loads this file itself; exporting it makes SDL recognize the
# GameStation controller before the engine opens its first controller.
if [ -z "${SDL_GAMECONTROLLERCONFIG:-}" ]; then
    if [ ! -r "$controller_config_file" ]; then
        printf 'Cannot read controller mapping: %s\n' "$controller_config_file" >&2
        exit 70
    fi

    # SDL splits this variable on newlines only; a semicolon join corrupts
    # every mapping after the first.
    SDL_GAMECONTROLLERCONFIG=$(sed -e 's/\r$//' -e '/^[[:space:]]*#/d' -e '/^[[:space:]]*$/d' \
        "$controller_config_file")
    if [ -z "$SDL_GAMECONTROLLERCONFIG" ]; then
        printf 'Controller mapping is empty: %s\n' "$controller_config_file" >&2
        exit 70
    fi
fi
export SDL_GAMECONTROLLERCONFIG

# Enter the game data directory (-game_dir or -j in any of its forms) so the
# log and config files land with the game rather than in the package folder.
scenario_dir=$game_dir
if [ -z "$scenario_dir" ]; then
    prev=
    for argument do
        if [ "$prev" = "-j" ]; then
            scenario_dir=$argument
            break
        fi
        case $argument in
            -j=*) scenario_dir=${argument#-j=} ;;
            -j?*) scenario_dir=${argument#-j} ;;
        esac
        prev=$argument
    done
fi

if [ -n "$scenario_dir" ] && [ -d "$scenario_dir" ]; then
    case $debug_log in
        ''|/*) ;;
        *) debug_log=$PWD/$debug_log ;;
    esac
    scenario_abs=$(CDPATH= cd "$scenario_dir" && pwd) || {
        printf 'Cannot enter game data directory: %s\n' "$scenario_dir" >&2
        exit 70
    }
    # Later -game_dir wins, so relative game paths survive the directory change.
    case $scenario_dir in
        /*) ;;
        *) set -- "$@" -game_dir "$scenario_abs" ;;
    esac
    cd "$scenario_abs" || {
        printf 'Cannot enter game data directory: %s\n' "$scenario_abs" >&2
        exit 70
    }
else
    cd "$package_dir" || {
        printf 'Cannot enter package directory: %s\n' "$package_dir" >&2
        exit 70
    }
fi

if [ "$debug" -eq 1 ]; then
    if [ -z "$debug_log" ]; then
        debug_log=/tmp/runtime-$(id -u)/rednukem-gsg.log
    fi
    debug_dir=$(dirname "$debug_log")
    if ! mkdir_error=$(mkdir -p "$debug_dir" 2>&1); then
        printf 'Cannot create diagnostic log directory %s: %s\n' "$debug_dir" "$mkdir_error" >&2
        exit 73
    fi
    if ! log_error=$( (umask 077; : > "$debug_log") 2>&1); then
        printf 'Cannot open diagnostic log %s: %s\n' "$debug_log" "$log_error" >&2
        exit 73
    fi
    if ! chmod 600 "$debug_log"; then
        printf 'Cannot restrict diagnostic log permissions: %s\n' "$debug_log" >&2
        exit 73
    fi

    {
        printf 'GSGDBG launcher: package=%s\n' "$package_dir"
        printf 'GSGDBG launcher: executable=%s\n' "$executable"
        printf 'GSGDBG launcher: library-path=%s\n' "$LD_LIBRARY_PATH"
        printf 'GSGDBG launcher: game-dir=%s\n' "$game_dir"
        printf 'GSGDBG launcher: force-ww2gi=%s\n' "$force_ww2gi"
        printf 'GSGDBG launcher: argument-count=%s\n' "$#"
        argument_index=1
        for argument do
            printf 'GSGDBG launcher: argv[%s].hex=' "$argument_index"
            printf '%s' "$argument" | LC_ALL=C od -An -v -tx1 | tr -d ' \n'
            printf '\n'
            argument_index=$((argument_index + 1))
        done
        if command -v cksum >/dev/null 2>&1; then
            cksum "$executable" | sed 's/^/GSGDBG launcher: executable-cksum=/'
            cksum "$controller_config_file" | sed 's/^/GSGDBG launcher: controller-db-cksum=/'
        else
            printf 'GSGDBG launcher: checksums=unavailable\n'
        fi
        printf 'GSGDBG launcher: starting Rednukem with LD_DEBUG=libs\n'
    } >>"$debug_log"
    printf 'GSGDBG launcher: executable=%s log=%s\n' "$executable" "$debug_log" >&2

    LD_DEBUG=libs "$executable" "$@" >>"$debug_log" 2>&1
    status=$?
    printf 'GSGDBG launcher: Rednukem exited with status=%s\n' "$status" >>"$debug_log"
    exit "$status"
fi

exec "$executable" "$@"
