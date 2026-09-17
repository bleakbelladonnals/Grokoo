#!/bin/zsh
set -euo pipefail

if [[ $# -ne 4 ]]; then
  print -u2 "usage: $0 <pid> <duration-seconds> <interval-seconds> <output-directory>"
  exit 64
fi

target_pid="$1"
duration_seconds="$2"
interval_seconds="$3"
output_directory="$4"

[[ "$target_pid" == <-> && "$duration_seconds" == <-> && "$interval_seconds" == <-> ]]
(( duration_seconds > 0 && interval_seconds > 0 && interval_seconds <= 30 ))
ps -p "$target_pid" >/dev/null

mkdir -p "$output_directory"
samples="$output_directory/samples.tsv"
summary="$output_directory/summary.txt"
print 'elapsed_seconds\tcpu_percent\trss_kb\tactivity_memory_mb' > "$samples"

started=$SECONDS
while (( SECONDS - started <= duration_seconds )); do
  elapsed=$((SECONDS - started))
  values=$(LC_ALL=C ps -p "$target_pid" -o %cpu=,rss= | awk 'NF == 2 { print $1, $2 }')
  if [[ -z "$values" ]]; then
    print -u2 "process $target_pid exited during sampling"
    exit 1
  fi
  read -r cpu rss <<< "$values"
  activity_memory=$(LC_ALL=C top -l 1 -pid "$target_pid" -stats pid,mem -n 1 \
    | awk -v pid="$target_pid" '
        $1 == pid {
          value = $2
          unit = substr(value, length(value), 1)
          number = value + 0
          if (unit == "K") number /= 1024
          else if (unit == "G") number *= 1024
          printf "%.3f", number
        }
      ')
  [[ -n "$activity_memory" ]]
  print "$elapsed\t$cpu\t$rss\t$activity_memory" >> "$samples"
  (( elapsed == duration_seconds )) && break
  remaining=$((duration_seconds - elapsed))
  (( remaining < interval_seconds )) && sleep "$remaining" || sleep "$interval_seconds"
done

awk -F '\t' '
  NR > 1 {
    count += 1
    cpu_sum += $2
    rss_sum += $3
    activity_memory_sum += $4
    if ($2 > cpu_max) cpu_max = $2
    if ($3 > rss_max) rss_max = $3
    if ($4 > activity_memory_max) activity_memory_max = $4
  }
  END {
    printf "samples=%d\n", count
    printf "average_cpu_percent=%.3f\n", cpu_sum / count
    printf "maximum_cpu_percent=%.3f\n", cpu_max
    printf "average_rss_mb=%.3f\n", rss_sum / count / 1024
    printf "maximum_rss_mb=%.3f\n", rss_max / 1024
    printf "average_activity_memory_mb=%.3f\n", activity_memory_sum / count
    printf "maximum_activity_memory_mb=%.3f\n", activity_memory_max
  }
' "$samples" > "$summary"

cat "$summary"
