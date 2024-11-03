# Define the dataset and parameters as before
DATASET=("Electronics" "dblp")
num_partitions=(2748 3300)
thread=32
len=${#DATASET[@]}
mem_sizes=(1.25 1.5 2.0 9.0)
interval=5 # Sampling interval in seconds

# Output directories as before
top_dir=result
base_dir=$top_dir/baseline
remap_dir=$top_dir/remap_only
merci_dir=$top_dir/merci

mkdir -p $top_dir $base_dir $remap_dir $merci_dir

# Define the metrics to monitor as before
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

# Function to capture initial metrics before executing any tests
capture_initial_metrics() {
    local dataset=$1
    local output_dir=$2
    
    # CSV file to store initial metric values
    initial_csv="${output_dir}/${dataset}_initial_metrics.csv"
    echo "metric,value" > "$initial_csv"

    echo "Capturing initial metrics for dataset $dataset..."
    for metric in "${metrics[@]}"; do
        # Capture each metric using a single perf stat command
        initial_value=$(perf stat -e "$metric" -a -- sleep 1 2>&1 | grep "$metric" | awk '{print $1}')
        
        # Save to CSV
        echo "$metric,$initial_value" >> "$initial_csv"
        
        # Print to terminal
        echo "Initial $metric: $initial_value"
    done

    echo "Initial metrics captured for dataset $dataset and saved to $initial_csv"
}

# Monitor and run the experiments as before, including the initial metric capture
monitor_metrics() {
    local dataset=$1
    local test_type=$2
    local output_dir=$3
    local num_partitions=$4
    local memory_ratio=$5

    # Prepare output CSV file with headers as before
    csv_file="${output_dir}/${dataset}_${test_type}_${memory_ratio}X.csv"
    echo "timestamp,${metrics[*]},cpu_utilization,total_time" > "$csv_file"

    # Start monitoring with perf, saving metrics periodically
    perf stat -e "${metrics[*]}" -I $((interval * 1000)) -o "$csv_file" -x, --append &
    perf_pid=$!

    # Start the appropriate test based on type as before
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

    # Calculate and store summary metrics as before
    end_time=$(date +%s)
    total_time=$((end_time - start_time))
    cpu_utilization=$(top -bn1 | grep "Cpu(s)" | awk '{print $2 + $4}') # Adjust as needed

    # Stop perf monitoring as before
    kill -INT $perf_pid

    # Append summary row
    echo "Total,${total_time},${cpu_utilization}" >> "$csv_file"
}

# Main execution
for ((i = 0; i < len; i++)); do
    dataset=${DATASET[$i]}
    partitions=${num_partitions[$i]}
    
    # Capture initial metrics before executing the tests
    capture_initial_metrics "$dataset" "$top_dir"

    # Baseline evaluation as before
    echo "Running baseline evaluation for dataset $dataset"
    monitor_metrics "$dataset" "baseline" "$base_dir" "$partitions" ""

    # Remap-only evaluation as before
    echo "Running remap-only evaluation for dataset $dataset"
    monitor_metrics "$dataset" "remap_only" "$remap_dir" "$partitions" ""

    # MERCI evaluation for different memory sizes
    for mem in "${mem_sizes[@]}"; do
        echo "Running MERCI evaluation for dataset $dataset with memory ratio $mem"
        monitor_metrics "$dataset" "merci" "$merci_dir" "$partitions" "$mem"
    done
done
