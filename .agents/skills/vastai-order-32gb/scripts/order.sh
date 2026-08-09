#!/usr/bin/env bash
set -euo pipefail

disk="${VAST_DISK_GB:-80}"
limit="${VAST_OFFER_LIMIT:-20}"

# Required, no default: which GPU API the workload needs, and the lowest
# version that will run it.  There is no sensible default — a rental is only
# useful if the host can run *your* binaries, and Vast rents plenty of
# machines whose driver predates whatever the image was built against.
#   VAST_ACCEL="cuda>=13.0"   filters on Vast's own cuda_vers field
#   VAST_ACCEL="vulkan>=1.3"  filters on driver_version; Vast reports no
#                             Vulkan version, and the driver is what decides it
[[ ${VAST_ACCEL:-} =~ ^(cuda|vulkan)\>=([0-9]+(\.[0-9]+)*)$ ]] || {
    echo "order.sh: set VAST_ACCEL to cuda>=<version> or vulkan>=<version>," \
         "e.g. VAST_ACCEL='cuda>=13.0' or VAST_ACCEL='vulkan>=1.3'" >&2
    exit 2
}
accel_api="${BASH_REMATCH[1]}"
accel_ver="${BASH_REMATCH[2]}"

# NVIDIA driver branch that first shipped each Vulkan version in a general
# release (developer.nvidia.com/vulkan-driver): 1.2 in r440, 1.4 in 550.40.81
# (Dec 2024).  1.3 uses r510, the minimum DXVK also requires for it.
min_driver=0
if [[ $accel_api == vulkan ]]; then
    case "$accel_ver" in
        1.2) min_driver=440 ;;
        1.3) min_driver=510 ;;
        1.4) min_driver=550 ;;
        *)
            echo "order.sh: no recorded NVIDIA driver requirement for Vulkan $accel_ver;" \
                 "known: 1.2, 1.3, 1.4" >&2
            exit 2
            ;;
    esac
fi

query="gpu_ram>=32 num_gpus=1 rentable=true disk_space>=$disk inet_down>=200 direct_port_count>=2 verified=true reliability>=0.98"
[[ $accel_api == cuda ]] && query="cuda_vers>=$accel_ver $query"

need() { command -v "$1" >/dev/null || { echo "order.sh: $1 is required" >&2; exit 1; }; }
need vastai
need jq

offers() {
    # The driver filter is a no-op for cuda (min_driver stays 0); Vast's own
    # cuda_vers already covers that case server-side.
    vastai search offers --raw "$query" -o dph --limit "$limit" --storage "$disk" |
        jq --argjson mindrv "$min_driver" \
            '[.[] | select(((.driver_version // "0") | split(".")[0] | tonumber) >= $mindrv)]'
}

case "${1:-list}" in
    list)
        offers | jq '[.[] | {
            gpu_name, vram_gb:(.gpu_ram / 1000), compute_cap,
            dph_total, reliability, inet_down, disk_space, cpu_ram,
            cpu_cores_effective, driver_version, geolocation, direct_port_count
        }]'
        ;;
    create)
        [[ -n ${VAST_MAX_DPH:-} ]] || {
            echo "order.sh: set VAST_MAX_DPH to an explicit total hourly price cap" >&2
            exit 2
        }
        # No default: the label is how a rental is traced back to the work it
        # belongs to, and a shared fallback makes every instance look alike.
        [[ ${VAST_LABEL:-} =~ ^[A-Za-z0-9][A-Za-z0-9_.-]{2,63}$ ]] || {
            echo "order.sh: set VAST_LABEL to a name identifying this project (3-64 chars, [A-Za-z0-9_.-])" >&2
            exit 2
        }
        # Vast regenerates offer and machine ids between searches, so select
        # and consume one current offer in this invocation.
        offer="$(offers | jq --arg gpu "${VAST_GPU_NAME:-}" \
            '[.[] | select(($gpu == "") or (.gpu_name == $gpu))][0:1]')"
        [[ $(jq 'length' <<<"$offer") -eq 1 ]] || {
            echo "order.sh: no current offer matches VAST_GPU_NAME=${VAST_GPU_NAME:-any}" >&2
            exit 1
        }
        price="$(jq -r '.[0].dph_total' <<<"$offer")"
        awk -v price="$price" -v cap="$VAST_MAX_DPH" 'BEGIN { exit !(price <= cap) }' || {
            echo "order.sh: offer costs \$$price/h including storage, above \$$VAST_MAX_DPH/h" >&2
            exit 1
        }
        user_id="$(vastai show user --raw | jq -r '.id')"
        template="$(vastai search templates --raw "creator_id=$user_id" |
            jq -r '[.[] | select(.name == "plan-ai-base") | .hash_id] | unique | if length == 1 then .[0] else empty end')"
        [[ -n $template ]] || {
            echo "order.sh: could not resolve exactly one plan-ai-base template" >&2
            exit 1
        }
        offer_id="$(jq -r '.[0].id' <<<"$offer")"
        gpu="$(jq -r '.[0].gpu_name' <<<"$offer")"
        echo "Renting $gpu offer $offer_id at \$$price/h with ${disk} GiB disk via plan-ai-base as '$VAST_LABEL'" >&2
        created="$(vastai create instance "$offer_id" --template_hash "$template" --disk "$disk" \
            --direct --cancel-unavail --label "$VAST_LABEL")"
        contract="$(sed -n "s/.*'new_contract': \([0-9][0-9]*\).*/\1/p" <<<"$created")"
        [[ -n $contract ]] || {
            echo "order.sh: create returned no instance id" >&2
            exit 1
        }
        # The CLI response also contains an instance-scoped API key. Never
        # print it into an agent transcript or shell log.
        printf '{"success":true,"new_contract":%s}\n' "$contract"
        ;;
    *)
        echo "usage: order.sh [list | create]" >&2
        exit 2
        ;;
esac
