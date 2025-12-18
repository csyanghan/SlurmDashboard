import json
import os
import argparse
from datetime import datetime, timedelta
from rich.console import Console, Group
from rich.table import Table
from rich.panel import Panel
from rich.text import Text
from rich.box import ROUNDED


def format_pill(value,
                thresholds,
                text_template="{}%"):
    """Formats a value with a colored pill style based on thresholds."""
    text = text_template.format(value)
    if value >= thresholds['alert']:
        style = "white on red"
    elif value >= thresholds['warn']:
        style = "black on yellow"
    else:
        style = "white on green"
    return Text(f" {text} ", style=style)


def format_placeholder_status(job):
    """Determines if a job is a placeholder."""
    job_name = (job.get('job_name', '') or '').strip().lower()
    if job.get('is_placeholder') == 'true':
        return Text("占位", style="yellow")
    if job_name in ('bash', 'interactive'):
        return Text("疑似占位", style="yellow")
    return "否"


def display_gpu_status(status_file,
                       notices_file,
                       console_width):
    """
    Parses status and notices JSON files and prints a rich dashboard to the console,
    mimicking the layout of index.html.
    """
    try:
        terminal_width = os.get_terminal_size().columns
    except OSError:
        terminal_width = console_width  # Fallback width
    
    console_width_min = min(terminal_width, console_width)
    console = Console(width=console_width_min)
    
    # --- Load Data ---
    try:
        with open(status_file, 'r', encoding='utf-8') as f:
            data = json.load(f)
    except FileNotFoundError:
        console.print(f"[bold red]错误: 未找到文件 '{status_file}'。[/bold red]")
        return
    except json.JSONDecodeError:
        console.print(f"[bold red]错误: 解析 JSON 文件 '{status_file}' 失败。[/bold red]")
        return
    
    notices_data = []
    try:
        with open(notices_file, 'r', encoding='utf-8') as f:
            notices_data = json.load(f).get("notices", [])
    except (FileNotFoundError, json.JSONDecodeError):
        # Notices are optional, so we don't show an error if it's missing/invalid
        pass
    
    # --- Page Header ---
    timestamp_str = data.get('timestamp', 'N/A')
    if timestamp_str != 'N/A':
        # Attempt to parse the timestamp and add 8 hours
        dt_object = datetime.strptime(timestamp_str, "%Y-%m-%dT%H:%M:%SZ")
        dt_object += timedelta(hours=8)
        timestamp = dt_object.strftime("%Y-%m-%d %H:%M:%S (UTC+8)")
    else:
        timestamp = 'N/A'
    header_text = Text.assemble(("集群 GPU 状态\n", "bold white"), (f"最后更新: {timestamp}", "cyan"), justify="center")
    console.print(Panel(header_text, box=ROUNDED, border_style="dim"))
    console.print()
    
    # --- Notices ---
    if notices_data:
        notice_text = Text(justify="center")
        for i, notice in enumerate(notices_data):
            notice_text.append("▪ ", style="yellow")
            if notice.get("date"):
                notice_text.append(f"[{notice['date']}] ", style="bold blue")
            if notice.get("title"):
                notice_text.append(f"{notice['title']}", style="bold")
            notice_text.append("\n")
            notice_text.append(f"  {notice.get('message', '')}")
            if i < len(notices_data) - 1:
                notice_text.append("\n\n")
        
        console.print(Panel(notice_text, title="[bold]公告[/bold]", border_style="yellow"))
        console.print()
    
    # --- GPU Usage ---
    gpu_entries = data.get("gpu_status", [])
    if gpu_entries:
        grouped_by_node = {}
        for gpu in gpu_entries:
            grouped_by_node.setdefault(gpu['node'], []).append(gpu)
        
        total_gpu_count = len(gpu_entries)
        total_allocated_from_nodes = 0
        for node, gpus in grouped_by_node.items():
            if gpus:
                gres_allocated_str = gpus[0].get('gres_allocated', '0')
                total_allocated_from_nodes += int(gres_allocated_str) if gres_allocated_str.isdigit() else 0
        
        idle_count = total_gpu_count - total_allocated_from_nodes
        
        gpu_remark = f"[空闲 GPU {idle_count}/{total_gpu_count}]"
        
        renderables = []
        node_items = sorted(grouped_by_node.items())
        for i, (node, gpus) in enumerate(node_items):
            gpus.sort(key=lambda x: x['gpu_index'])
            active_count = sum(1 for g in gpus if (g.get('gpu_util', 0) > 0 or g.get('mem_percent', 0) > 0))
            peak_gpu_util = max(g.get('gpu_util', 0) for g in gpus)
            peak_mem = max(g.get('mem_percent', 0) for g in gpus)
            allocated_count = int(gpus[0].get('gres_allocated', 0)) if gpus and gpus[0].get('gres_allocated', '0').isdigit() else 0
            total_count = len(gpus)
            
            summary = (f"活跃 {active_count}/{total_count} · "
                       f"峰值 GPU {peak_gpu_util}% · "
                       f"峰值显存 {peak_mem}%")
            node_header = Text()
            node_header.append(f"{node} ", style="bold cyan")
            node_header.append(f"[{allocated_count}/{total_count}] ", style="dim")
            node_header.append(summary, style="grey70")
            renderables.append(node_header)
            
            gpu_table = Table(box=None, padding=(0, 1), show_header=False, show_edge=False)
            gpu_table.add_column("Details")
            
            for j, gpu in enumerate(gpus):
                details = Text()
                if j != len(gpus) - 1:
                    details.append("├─ ")
                else:
                    details.append("└─ ")
                details.append(f"GPU {gpu['gpu_index']}: ")
                details.append("计算 ", style="dim")
                details.append(format_pill(gpu['gpu_util'], {
                    'warn': 70,
                    'alert': 90
                }, text_template="{: >3}% "))
                details.append(" 显存 ", style="dim")
                details.append(format_pill(gpu['mem_percent'], {
                    'warn': 80,
                    'alert': 90
                }, text_template="{: >3}% "))
                details.append(f" {gpu['mem_used_mb']:,}/{gpu['mem_total_mb']:,} MB", style="dim")
                gpu_table.add_row(details)
            
            renderables.append(gpu_table)
            
            if i < len(node_items) - 1:
                renderables.append(Text(""))
        
        gpu_panel_content = Group(*renderables)
        console.print(Panel(gpu_panel_content, title=f"[bold]GPU 使用情况[/bold] {gpu_remark}", border_style="green"))
        console.print()
    
    # --- Running Jobs ---
    running_jobs = data.get("running_jobs", [])
    if running_jobs:
        running_table = Table(title="[bold]运行中的作业[/bold]", border_style="blue", box=ROUNDED)
        headers = ["作业 ID", "用户", "分区", "作业名", "节点", "分配节点", "GRES", "耗时", "CPU", "内存", "占位"]
        for header in headers:
            running_table.add_column(header, justify="left")
        
        for job in running_jobs:
            running_table.add_row(job.get("job_id", "-"),
                                  job.get("user", "-"),
                                  job.get("partition", "-"),
                                  job.get("job_name", "-"),
                                  job.get("nodes", "-"),
                                  job.get("allocated_nodes", "-"),
                                  job.get("gres", "-"),
                                  job.get("time_used", "-"),
                                  job.get("cpus", "-"),
                                  job.get("mem", "-"),
                                  format_placeholder_status(job), )
        console.print(running_table, justify="center")
        console.print()
    else:
        console.print("[bold green]当前没有运行中的作业。[/bold green]", justify="center")
        console.print()
    
    # --- Queued Jobs ---
    queued_jobs = data.get("queued_jobs", [])
    if queued_jobs:
        queued_table = Table(title="[bold]排队中的作业[/bold]", border_style="yellow", box=ROUNDED)
        headers = ["作业 ID", "用户", "分区", "作业名", "节点", "GRES", "限制", "CPU", "内存", "占位"]
        for header in headers:
            queued_table.add_column(header, justify="left")
        
        for job in queued_jobs:
            queued_table.add_row(job.get("job_id", "-"),
                                 job.get("user", "-"),
                                 job.get("partition", "-"),
                                 job.get("job_name", "-"),
                                 job.get("nodes", "-"),
                                 job.get("gres", "-"),
                                 job.get("time_limit", "-"),
                                 job.get("cpus", "-"),
                                 job.get("mem", "-"),
                                 format_placeholder_status(job), )
        console.print(queued_table, justify="center")
    else:
        console.print("[bold green]当前没有排队中的作业。[/bold green]", justify="center")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Display GPU status from a JSON file.")
    parser.add_argument('--status-file', '-s', default='/public/share/gpu_status/gpu_status.json', help='Path to the GPU status JSON file.')
    parser.add_argument('--notices-file', '-n', default='/public/share/gpu_status/notices.json', help='Path to the notices JSON file.')
    parser.add_argument('--console-width', '-w', type=int, default=150, help='Width of the console output.')
    args = parser.parse_args()
    
    display_gpu_status(status_file=args.status_file, notices_file=args.notices_file, console_width=args.console_width)
