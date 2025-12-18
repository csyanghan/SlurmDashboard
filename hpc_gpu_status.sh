#!/bin/bash

# Allow deployers to override cluster-specific paths/partitions via env vars.
PARTITIONS=${PARTITIONS:-"gpu_partition"}
JSON_OUTPUT=${JSON_OUTPUT:-"./gpu_status.json"}
SLURM_PREFIX=${SLURM_PREFIX:-"/opt/slurm"}
SQUEUE_BIN=${SQUEUE_BIN:-"$SLURM_PREFIX/bin/squeue"}
SINFO_BIN=${SINFO_BIN:-"$SLURM_PREFIX/bin/sinfo"}
SCONTROL_BIN=${SCONTROL_BIN:-"$SLURM_PREFIX/bin/scontrol"}
SSH_BIN=${SSH_BIN:-"ssh"}
NVIDIA_SMI_BIN=${NVIDIA_SMI_BIN:-"nvidia-smi"}

# 检查占卡脚本的函数
check_placeholder_script() {
    local job_id="$1"
    local is_placeholder="false"
    
    # 获取任务的详细信息
    local job_info=$("$SCONTROL_BIN" show job "$job_id" 2>/dev/null)
    
    # 提取脚本路径和工作目录
    local script_path=$(echo "$job_info" | grep "Command=" | cut -d= -f2-)
    local work_dir=$(echo "$job_info" | grep "WorkDir=" | cut -d= -f2-)
    
    # 如果找到脚本文件，检查其内容
    if [ -n "$script_path" ] && [ -n "$work_dir" ]; then
        # 处理相对路径
        if [[ "$script_path" != /* ]]; then
            script_path="$work_dir/$script_path"
        fi
        
        # 尝试读取脚本文件内容
        local script_content=""
        if [ -f "$script_path" ]; then
            script_content=$(head -100 "$script_path" 2>/dev/null)
        elif [ -n "$SLURM_SUBMIT_HOST" ] && [ "$SLURM_SUBMIT_HOST" != "localhost" ]; then
            script_content=$("$SSH_BIN" -o ConnectTimeout=2 "$SLURM_SUBMIT_HOST" "cat '$script_path'" 2>/dev/null)
        fi
        
        # 检查脚本内容是否包含占卡特征
        if echo "$script_content" | grep -qi "sleep.*[0-9]\+[dhms]\|placeholder\|占卡\|hold\|idle\|dummy\|while true\|infinite"; then
            is_placeholder="true"
        fi
    fi
    
    echo "$is_placeholder"
}

# 获取系统排队和运行任务信息
get_queue_info() {
    local state="$1"
    
    # 对于运行中的任务，获取节点信息
    if [ "$state" = "R" ]; then
        "$SQUEUE_BIN" --partition="$PARTITIONS" --state="$state" \
            --format="%i*%u*%P*%j*%N*%D*%M*%l*%C*%m*%t*%b" \
            --noheader 2>/dev/null | \
        while IFS='*' read -r job_id user partition job_name nodes_requested nodes time_used time_limit cpus mem state gres; do
            
            # 检查是否为占卡脚本
            local is_placeholder=$(check_placeholder_script "$job_id")
            
            
            # 输出JSON格式，添加allocated_nodes和gpu_allocation字段
            echo "{\"job_id\":\"$job_id\",\"user\":\"$user\",\"partition\":\"$partition\",\"job_name\":\"$job_name\",\"nodes\":\"$nodes\",\"allocated_nodes\":\"$nodes_requested\",\"time_used\":\"$time_used\",\"time_limit\":\"$time_limit\",\"cpus\":\"$cpus\",\"mem\":\"$mem\",\"state\":\"$state\",\"is_placeholder\":\"$is_placeholder\", \"gres\":\"$gres\"}"
        done
    else
        # 排队任务（状态为PD），不获取节点信息
        "$SQUEUE_BIN" --partition="$PARTITIONS" --state="$state" \
            --format="%i*%u*%P*%j*%D*%M*%l*%C*%m*%t*%b" \
            --noheader 2>/dev/null | \
        while IFS='*' read -r job_id user partition job_name nodes time_used time_limit cpus mem state gres; do
            # 检查是否为占卡脚本
            local is_placeholder=$(check_placeholder_script "$job_id")
            
            # 输出JSON格式，排队任务没有allocated_nodes
            echo "{\"job_id\":\"$job_id\",\"user\":\"$user\",\"partition\":\"$partition\",\"job_name\":\"$job_name\",\"nodes\":\"$nodes\",\"allocated_nodes\":\"\",\"gpu_allocation\":\"\",\"time_used\":\"$time_used\",\"time_limit\":\"$time_limit\",\"cpus\":\"$cpus\",\"mem\":\"$mem\",\"state\":\"$state\",\"is_placeholder\":\"$is_placeholder\",\"gres\":\"$gres\"}"
        done
    fi
}

# 获取分区节点列表
NODES=$("$SINFO_BIN" --partition="$PARTITIONS" -N -o "%N" | grep -v "NODELIST" | sort -u)

if [ -z "$NODES" ]; then
    NODES=$("$SINFO_BIN" --partition="$PARTITIONS" -o "%n" | tail -n +2 | sort -u)
fi

# 开始JSON对象
echo "{" > "$JSON_OUTPUT"

TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
echo "\"timestamp\": \"$TIMESTAMP\"," >> "$JSON_OUTPUT"

# 第一部分：GPU信息
echo '"gpu_status": [' >> "$JSON_OUTPUT"
first_gpu=true

# 查询每个节点的GPU信息
for NODE in $NODES; do

    NODE_INFO=$("$SCONTROL_BIN" show node "$NODE" 2>/dev/null)

    ALLOC_TRES=$(echo "$NODE_INFO" | grep "AllocTRES=" | sed 's/.*AllocTRES=//')
    # 从AllocTRES中提取gres/gpu的值
    GRES_ALLOCATED="0"
    if [[ "$ALLOC_TRES" == *gres/gpu=* ]]; then
        GRES_ALLOCATED=$(echo "$ALLOC_TRES" | grep -o "gres/gpu=[0-9]*" | cut -d= -f2)
    fi

    GPU_QUERY_ARGS="--query-gpu=index,utilization.gpu,utilization.memory,memory.used,memory.total --format=csv,noheader,nounits"
    GPU_INFO=$("$SSH_BIN" -o ConnectTimeout=5 "$NODE" \
    "$NVIDIA_SMI_BIN $GPU_QUERY_ARGS" 2>/dev/null)

    if [ -n "$GPU_INFO" ]; then
        while IFS= read -r LINE; do
            CLEAN_LINE=$(echo "$LINE" | sed 's/, */,/g')
            IFS=',' read -r index gpu_util mem_util mem_used mem_total <<< "$CLEAN_LINE"
            
            # 计算内存占用率（已使用内存占总量百分比）
            if [ "$mem_total" -gt 0 ]; then
                mem_percent=$((mem_used * 100 / mem_total))
            else
                mem_percent=0
            fi
            
            if [ "$first_gpu" = true ]; then
                printf '{"node":"%s","gpu_index":%s,"gpu_util":%s,"mem_util":%s,"mem_used_mb":%s,"mem_total_mb":%s,"mem_percent":%s,"gres_allocated":"%s"}' \
                    "$NODE" "$index" "$gpu_util" "$mem_util" "$mem_used" "$mem_total" "$mem_percent" "$GRES_ALLOCATED">> "$JSON_OUTPUT"
                first_gpu=false
            else
                printf ',\n{"node":"%s","gpu_index":%s,"gpu_util":%s,"mem_util":%s,"mem_used_mb":%s,"mem_total_mb":%s,"mem_percent":%s,"gres_allocated":"%s"}' \
                    "$NODE" "$index" "$gpu_util" "$mem_util" "$mem_used" "$mem_total" "$mem_percent" "$GRES_ALLOCATED">> "$JSON_OUTPUT"
            fi
        done <<< "$GPU_INFO"
    fi
    
done

echo -e "\n]," >> "$JSON_OUTPUT"

# 第二部分：排队任务信息
echo '"queued_jobs": [' >> "$JSON_OUTPUT"
QUEUED_JOBS=$(get_queue_info "PD")
first_queue=true

while IFS= read -r JOB_JSON; do
    if [ -n "$JOB_JSON" ]; then
        if [ "$first_queue" = true ]; then
            echo "$JOB_JSON" >> "$JSON_OUTPUT"
            first_queue=false
        else
            echo ",$JOB_JSON" >> "$JSON_OUTPUT"
        fi
    fi
done <<< "$QUEUED_JOBS"

echo -e "\n]," >> "$JSON_OUTPUT"

# 第三部分：运行中任务信息
echo '"running_jobs": [' >> "$JSON_OUTPUT"
RUNNING_JOBS=$(get_queue_info "R")
first_running=true

while IFS= read -r JOB_JSON; do
    if [ -n "$JOB_JSON" ]; then
        if [ "$first_running" = true ]; then
            echo "$JOB_JSON" >> "$JSON_OUTPUT"
            first_running=false
        else
            echo ",$JOB_JSON" >> "$JSON_OUTPUT"
        fi
    fi
done <<< "$RUNNING_JOBS"

echo -e "\n]" >> "$JSON_OUTPUT"

# 结束JSON对象
echo "}" >> "$JSON_OUTPUT"

echo "GPU信息和任务队列已保存到: $JSON_OUTPUT"
