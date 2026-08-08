#!/usr/bin/env bash
set -euo pipefail

disk="${VAST_DISK_GB:-80}"
limit="${VAST_OFFER_LIMIT:-20}"
query="cuda_vers>=13.0 gpu_ram>=32 num_gpus=1 rentable=true disk_space>=$disk inet_down>=200 direct_port_count>=2 verified=true reliability>=0.98"

need() { command -v "$1" >/dev/null || { echo "order.sh: $1 is required" >&2; exit 1; }; }
need vastai
need jq

offers() {
    vastai search offers --raw "$query" -o dph --limit "$limit" --storage "$disk"
}

case "${1:-list}" in
    list)
        offers | jq '[.[] | {
            id, gpu_name, vram_gb:(.gpu_ram / 1000), compute_cap,
            dph_total, reliability, inet_down, disk_space, cpu_ram,
            cpu_cores_effective, driver_version, geolocation, direct_port_count
        }]'
        ;;
    create)
        offer_id="${2:?usage: order.sh create OFFER_ID}"
        [[ $offer_id =~ ^[0-9]+$ ]] || { echo "order.sh: offer id must be numeric" >&2; exit 2; }
        [[ -n ${VAST_MAX_DPH:-} ]] || {
            echo "order.sh: set VAST_MAX_DPH to an explicit total hourly price cap" >&2
            exit 2
        }
        # Vast accepts `id=...` in the query grammar but returns an empty set
        # even for an offer it just listed. Re-fetch the constrained shortlist
        # and match locally so the hardware and price are still revalidated.
        offer="$(offers | jq --argjson id "$offer_id" '[.[] | select(.id == $id)]')"
        [[ $(jq 'length' <<<"$offer") -eq 1 ]] || {
            echo "order.sh: offer $offer_id no longer satisfies the 32 GB constraints" >&2
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
        echo "Renting offer $offer_id at \$$price/h with ${disk} GiB disk via plan-ai-base" >&2
        vastai create instance "$offer_id" --template_hash "$template" --disk "$disk" \
            --ssh --direct --cancel-unavail --label "plan-ai-32gb"
        ;;
    *)
        echo "usage: order.sh [list | create OFFER_ID]" >&2
        exit 2
        ;;
esac
