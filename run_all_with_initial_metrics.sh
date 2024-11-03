#!/bin/bash

# Dataset
DATASET=("amazon_Electronics")
num_partitions=(2748 3300)

# Variables
thread=32  # Hardware core count
len=${#DATASET[@]}
mem_sizes=(1.25 1.5 2.0 9.0)

# Output directories
top_dir=result
base_dir=$top_dir/baseline
remap_dir=$top_dir/remap_only
merci_dir=$top_dir/merci
perf_dir=$top_dir/perf_metrics

# Create necessary directories
mkdir -p $top_dir $base_dir $remap_dir $merci_dir $perf_dir

# CSV file path for storing metrics
perf_csv=$perf_dir/perf_metrics.csv

# Initialize CSV file with headers
echo "Dataset,Execution,Memory_Ratio,CPU_Cycles,Total_Instructions,Cache_Misses,Cache_References,Branch_Misses,Page_Faults,CPU_Utilization,Time_Taken,LLC_Load_Misses,LLC_Store_Misses,CAS_Count_Read,CAS_Count_Write" > $perf_csv

# Set up data directories
for (( i=0; i<$len; i++ )); do
    ./control_dir_path.sh ${DATASET[$i]} ${num_partitions[$i]}
done

# Function to run perf and capture metrics
run_perf() {
    local dataset=$1
    local execution=$2
    local mem_ratio=$3
    local output_file=$4

    # Run perf with required events
    perf stat -e \
        cpu-cycles,instructions,cache-misses,cache-references,branch-misses,page-faults,\
        cpu/LLC-load-misses/,cpu/LLC-store-misses/,uncore_imc/cas_count_read/,uncore_imc/cas_count_write/ \
        -a -- "$execution" > /dev/null 2> $output_file

    # Extract metrics from perf output
    cpu_cycles=$(grep "cpu-cycles" $output_file | awk '{print $1}')
    instructions=$(grep "instructions" $output_file | awk '{print $1}')
    cache_misses=$(grep "cache-misses" $output_file | awk '{print $1}')
    cache_references=$(grep "cache-references" $output_file | awk '{print $1}')
    branch_misses=$(grep "branch-misses" $output_file | awk '{print $1}')
    page_faults=$(grep "page-faults" $output_file | awk '{print $1}')
    llc_load_misses=$(grep "LLC-load-misses" $output_file | awk '{print $1}')
    llc_store_misses=$(grep "LLC-store-misses" $output_file | awk '{print $1}')
    cas_count_read=$(grep "cas_count_read" $output_file | awk '{print $1}')
    cas_count_write=$(grep "cas_count_write" $output_file | awk '{print $1}')

    # Calculate CPU utilization and time taken
    cpu_utilization=$(grep "CPU utilization" $output_file | awk '{print $1}')
    time_taken=$(grep "seconds time elapsed" $output_file | awk '{print $1}')

    # Append metrics to CSV
    echo "$dataset,$execution,$mem_ratio,$cpu_cycles,$instructions,$cache_misses,$cache_references,$branch_misses,$page_faults,$cpu_utilization,$time_taken,$llc_load_misses,$llc_store_misses,$cas_count_read,$cas_count_write" >> $perf_csv
}

# 1. Preprocess
cd 1_preprocess/scripts
python3 amazon_parse_divide_filter.py Office_Products
./lastfm_dblp.sh dblp

# 2. Partition
cd ../../2_partition/scripts
for (( i=0; i<$len; i++ )); do
    ./run_patoh.sh ${DATASET[$i]} ${num_partitions[$i]}
done

# 3. Clustering
cd ../../3_clustering
mkdir -p bin
make

# 4. Performance Evaluation
cd ../4_performance_evaluation
mkdir -p bin
make all

# Baseline
for dataset in ${DATASET[@]}; do
    echo "Running baseline on dataset $dataset"
    sync && echo 1 > /proc/sys/vm/drop_caches
    output_file="$perf_dir/${dataset}_baseline_perf.txt"
    run_perf $dataset "./bin/eval_baseline -d $dataset -c $thread -r 5" "N/A" $output_file
done

# Remap only
for (( i=0; i<$len; i++ )); do
    dataset=${DATASET[$i]}
    echo "Running remap-only on dataset $dataset"
    ../3_clustering/bin/clustering -d $dataset -p ${num_partitions[$i]} --remap-only
    sync && echo 1 > /proc/sys/vm/drop_caches
    output_file="$perf_dir/${dataset}_remap_only_perf.txt"
    run_perf $dataset "./bin/eval_remap_only -d $dataset -c $thread -r 5 -p ${num_partitions[$i]}" "N/A" $output_file
done

# MERCI with different memory ratios
for (( i=0; i<$len; i++ )); do
    dataset=${DATASET[$i]}
    echo "Running MERCI on dataset $dataset"
    ../3_clustering/bin/clustering -d $dataset -p ${num_partitions[$i]}
    for mem in ${mem_sizes[@]}; do
        sync && echo 1 > /proc/sys/vm/drop_caches
        output_file="$perf_dir/${dataset}_merci_${mem}X_perf.txt"
        run_perf $dataset "./bin/eval_merci -d $dataset -p ${num_partitions[$i]} --memory_ratio $mem -c $thread -r 5" $mem $output_file
    done
done
