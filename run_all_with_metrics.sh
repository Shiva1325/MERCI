#!/bin/bash

# Datasets and Parameters
DATASET=("amazon_Office_Products" "dblp")
num_partitions=(2748 3300)
thread=32
len=${#DATASET[@]}
mem_sizes=(1.25 1.5 2.0 9.0)
interval=5 # Sampling interval in seconds

# Output directories
top_dir=result
base_dir=$top_dir/baseline
remap_dir=$top_dir/remap_only
merci_dir=$top_dir/merci

mkdir -p $top_dir $base_dir $remap_dir $merci_dir

# Metrics to track
metrics=(
    'cpu-cycles'
    'instructions'
    'cache-misses'
    'cache-references'
    'branch-misses'
    'page-faults'
    'cpu/LLC-load-misses/'
    'cpu/LLC-store-misses/'
    'uncore_imc/cas_count_read/'
    'uncore_imc/cas_count_write/'
)

# Helper function to monitor NUMA-related metrics
monitor_metrics() {
    local dataset=$1
    local test_type=$2
    local output_dir=$3
    local num_partitions=$4
    local memory_ratio=$5

    # Prepare output CSV file with headers
    csv_file="${output_dir}/${dataset}_${test_type}_${memory_ratio}X.csv"
    echo "timestamp,${metrics[*]},cpu_utilization,total_time" > "$csv_file"

    # Start monitoring with perf, saving metrics periodically
    perf stat -e "${metrics[*]}" -I $((interval * 1000)) -o "$csv_file" -x, --append &
    perf_pid=$!

    # Track the start time
    start_time=$(date +%s)

    # Execute test
    case $test_type in
        "baseline")
            sync && echo 1 > /proc/sys/vm/drop_caches
            ./bin/eval_baseline -d $dataset -c $thread -r 5
            ;;
        "remap_only")
            ../3_clustering/bin/clustering -d $dataset -p $num_partitions --remap-only
            sync && echo 1 > /proc/sys/vm/drop_caches
            ./bin/eval_remap_only -d $dataset -c $thread -r 5 -p $num_partitions
            ;;
        "merci")
            ../3_clustering/bin/clustering -d $dataset -p $num_partitions
            sync && echo 1 > /proc/sys/vm/drop_caches
            ./bin/eval_merci -d $dataset -p $num_partitions --memory_ratio $memory_ratio -c $thread -r 5
            ;;
    esac

    # Calculate total time and CPU utilization
    end_time=$(date +%s)
    total_time=$((end_time - start_time))
    cpu_utilization=$(top -bn1 | grep "Cpu(s)" | awk '{print $2 + $4}') # Adjust as needed

    # Stop perf monitoring
    kill -INT $perf_pid

    # Append summary row
    echo "Total,${total_time},${cpu_utilization}" >> "$csv_file"
}

# Loop through datasets and configurations
for ((i = 0; i < len; i++)); do
    dataset=${DATASET[$i]}
    partitions=${num_partitions[$i]}
    
    # Baseline evaluation
    echo "Running baseline evaluation for dataset $dataset"
    monitor_metrics "$dataset" "baseline" "$base_dir" "$partitions" ""

    # Remap-only evaluation
    echo "Running remap-only evaluation for dataset $dataset"
    monitor_metrics "$dataset" "remap_only" "$remap_dir" "$partitions" ""

    # MERCI evaluation for different memory sizes
    for mem in "${mem_sizes[@]}"; do
        echo "Running MERCI evaluation for dataset $dataset with memory ratio $mem"
        monitor_metrics "$dataset" "merci" "$merci_dir" "$partitions" "$mem"
    done
done
