#!/bin/bash

# Dataset and Partition Parameters
DATASET=("amazon_All_Beauty" "amazon_Magazine_Subscriptions" "amazon_Cell_Phones_and_Accessories" "amazon_Clothing_Shoe_and_Jewelry" "amazon_Video_Games" "amazon_Pet_Supplies" "amazon_Electronics" "dblp")
num_partitions=(1272 682 6340 7200 2430 2134 3720 3300)
DATASET_SIZE=("All_Beauty" "Magazine_Subscriptions" "Cell_Phones_and_Accessories" "Clothing_Shoe_and_Jewelry" "Video_Games" "Pet_Supplies" "Electronics")
# Thread settings
threads=(32 64 128 256)
len=${#DATASET[@]}
mem_sizes=(1.25 1.5 2.0 3.0 6.0 9.0)

# Output directories
top_dir=~/MERCI/result
base_dir=$top_dir/baseline
remap_dir=$top_dir/remap_only
merci_dir=$top_dir/merci

mkdir -p $top_dir $base_dir $remap_dir $merci_dir

# Calculate dataset sizes
dataset_sizes=()
# Path to the dataset directory
dataset_dir=~/MERCI/data/1_raw_data/amazon

# Calculate dataset sizes
for dataset in "${DATASET_SIZE[@]}"; do
    dataset_path="$dataset_dir/$dataset.json.gz"  # Update the extension if needed
    if [ -f "$dataset_path" ]; then
        dataset_size_bytes=$(stat -c%s "$dataset_path")  # Get size in bytes
        dataset_size_gb=$(echo "scale=3; $dataset_size_bytes / (1024^3)" | bc)  # Convert to GB with 3 decimal places
        dataset_sizes+=("$dataset_size_gb")
    else
        echo "Warning: Dataset file $dataset_path not found. Defaulting size to 0 GB."
        dataset_sizes+=("0")
    fi
done

# Set up data directories
for (( i=0; i<$len; i++ )); do
    ./control_dir_path.sh ${DATASET[$i]} ${num_partitions[$i]}
done

# CSV file for perf metrics
metrics_file="$top_dir/perf_metrics.csv"

# Ensure perf metrics files exist
for dataset in "${DATASET[@]}"; do
    sudo touch "$perf_dir/${dataset}_baseline_perf.txt"
    sudo touch "$perf_dir/${dataset}_remap_only_perf.txt"
    for mem in "${mem_sizes[@]}"; do
        sudo touch "$perf_dir/${dataset}_merci_${mem}X_perf.txt"
    done
done

# Ensure the CSV file exists and has headers
if [ ! -f "$metrics_file" ]; then
    echo "Dataset,Dataset_Size,Mode,Memory_Ratio,Threads,Cycles,Instructions,Cache_Misses,Cache_References,Branch_Misses,Page_Faults,LLC_Load_Misses,LLC_Store_Misses,CAS_Count_Read,CAS_Count_Write,Time_Elapsed" > "$metrics_file"
fi

# Check for valid metrics using `perf list`
valid_metrics=()
for metric in cpu-cycles instructions cache-misses cache-references branch-misses page-faults LLC-load-misses LLC-store-misses uncore_imc/cas_count_read/ uncore_imc/cas_count_write/; do
    if perf list | grep -q "$metric"; then
        valid_metrics+=("$metric")
    fi
done

# Function to run perf and capture metrics
run_perf() {
    local cmd=$1
    local dataset=$2
    local dataset_size=$3
    local mode=$4
    local mem_ratio=$5
    local thread=$6

    # Run perf and capture output
    perf stat -e $(IFS=, ; echo "${valid_metrics[*]}") -a -- $cmd 2>&1 | tee perf_output.txt

    # Parse perf metrics
    cycles=$(grep "cpu-cycles" perf_output.txt | awk '{print $1}')
    instructions=$(grep "instructions" perf_output.txt | awk '{print $1}')
    cache_misses=$(grep "cache-misses" perf_output.txt | awk '{print $1}')
    cache_references=$(grep "cache-references" perf_output.txt | awk '{print $1}')
    branch_misses=$(grep "branch-misses" perf_output.txt | awk '{print $1}')
    page_faults=$(grep "page-faults" perf_output.txt | awk '{print $1}')
    llc_load_misses=$(grep "LLC-load-misses" perf_output.txt | awk '{print $1}')
    llc_store_misses=$(grep "LLC-store-misses" perf_output.txt | awk '{print $1}')
    cas_count_read=$(grep "uncore_imc/cas_count_read/" perf_output.txt | awk '{print $1}')
    cas_count_write=$(grep "uncore_imc/cas_count_write/" perf_output.txt | awk '{print $1}')
    time_elapsed=$(grep "seconds time elapsed" perf_output.txt | awk '{print $1}')

    # Append to CSV
    echo "$dataset,$dataset_size,$mode,$mem_ratio,$thread,$cycles,$instructions,$cache_misses,$cache_references,$branch_misses,$page_faults,$llc_load_misses,$llc_store_misses,$cas_count_read,$cas_count_write,$time_elapsed" >> "$metrics_file"

    # Cleanup
    rm -f perf_output.txt
}

# Preprocess Step
cd 1_preprocess/scripts
python3 amazon_parse_divide_filter.py All_Beauty
python3 amazon_parse_divide_filter.py Magazine_Subscriptions
python3 amazon_parse_divide_filter.py Cell_Phones_and_Accessories
python3 amazon_parse_divide_filter.py Pet_Supplies
python3 amazon_parse_divide_filter.py Video_Games
python3 amazon_parse_divide_filter.py Electronics
python3 amazon_parse_divide_filter.py Clothing_Shoes_and_Jewelry
./lastfm_dblp.sh dblp

# Partition Step
cd ../../2_partition/scripts
for ((i = 0; i < $len; i++)); do
    ./run_patoh.sh ${DATASET[$i]} ${num_partitions[$i]}
done

# Clustering Step
cd ../../3_clustering
mkdir -p bin
make

# Performance Evaluation Step
cd ../4_performance_evaluation
mkdir -p bin
make all

# Baseline
for ((i = 0; i < $len; i++)); do
    dataset=${DATASET[$i]}
    dataset_size=${dataset_sizes[$i]}
    for thread in ${threads[@]}; do
        printf "\nRunning baseline on dataset %s with %d threads\n" $dataset $thread
        sync && sudo sh -c 'echo 1 > /proc/sys/vm/drop_caches'
        run_perf "./bin/eval_baseline -d $dataset -c $thread -r 15" $dataset $dataset_size "Baseline" "N/A" $thread
    done
done

# Remap only
for ((i = 0; i < $len; i++)); do
    dataset=${DATASET[$i]}
    dataset_size=${dataset_sizes[$i]}
    partitions=${num_partitions[$i]}
    for thread in ${threads[@]}; do
        printf "\nRunning remap-only on dataset %s with %d threads\n" $dataset $thread
        ../3_clustering/bin/clustering -d $dataset -p $partitions --remap-only
        sync && sudo sh -c 'echo 1 > /proc/sys/vm/drop_caches'
        run_perf "./bin/eval_remap_only -d $dataset -c $thread -r 15 -p $partitions" $dataset $dataset_size "Remap-Only" "N/A" $thread
    done
done

# MERCI with various memory ratios
for ((i = 0; i < $len; i++)); do
    dataset=${DATASET[$i]}
    dataset_size=${dataset_sizes[$i]}
    partitions=${num_partitions[$i]}
    for mem in ${mem_sizes[@]}; do
        for thread in ${threads[@]}; do
            printf "\nRunning MERCI on dataset %s with memory ratio %s and %d threads\n" $dataset $mem $thread
            ../3_clustering/bin/clustering -d $dataset -p $partitions
            sync && sudo sh -c 'echo 1 > /proc/sys/vm/drop_caches'
            run_perf "./bin/eval_merci -d $dataset -p $partitions --memory_ratio $mem -c $thread -r 15" $dataset $dataset_size "MERCI" "$mem" $thread
        done
    done
done
