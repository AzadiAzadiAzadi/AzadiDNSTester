#!/bin/bash

# ==============================================================================
# Azadi DNS Tester - Bash Edition (No Dependencies)
# ==============================================================================
# Tests DNS servers from dns_servers.txt and saves working ones to working_dns.txt
# Supports ANY input format - extracts ALL IPv4 addresses automatically
# No external dependencies - uses only built-in tools (dig/host/nslookup)
# ==============================================================================

set -o pipefail

# Get script directory (works even with symlinks)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INPUT_FILE="$SCRIPT_DIR/dns_servers.txt"
OUTPUT_FILE="$SCRIPT_DIR/working_dns.txt"

# Defaults
DEFAULT_WORKERS=100
DEFAULT_TIMEOUT=3
DEFAULT_DOMAIN="google.com"

# Colors (disable if not terminal)
if [[ -t 1 ]]; then
    GREEN='\033[0;32m'
    RED='\033[0;31m'
    YELLOW='\033[1;33m'
    CYAN='\033[0;36m'
    NC='\033[0m' # No Color
else
    GREEN='' RED='' YELLOW='' CYAN='' NC=''
fi

# ==============================================================================
# Utility Functions
# ==============================================================================

# Detect available DNS lookup tool
detect_dns_tool() {
    if command -v dig &>/dev/null; then
        echo "dig"
    elif command -v host &>/dev/null; then
        echo "host"
    elif command -v nslookup &>/dev/null; then
        echo "nslookup"
    else
        echo ""
    fi
}

# Check if perl is available for high-precision timing
has_perl_hires() {
    perl -MTime::HiRes -e '1' 2>/dev/null
}

# Get current time in milliseconds
get_time_ms() {
    if has_perl_hires; then
        perl -MTime::HiRes=time -e 'printf "%.0f\n", time * 1000'
    elif [[ "$(uname)" == "Linux" ]]; then
        echo $(($(date +%s%N) / 1000000))
    else
        # macOS fallback - second precision only
        echo $(($(date +%s) * 1000))
    fi
}

# ==============================================================================
# DNS Testing Functions
# ==============================================================================

# Test DNS with dig
test_dns_dig() {
    local server="$1"
    local domain="$2"
    local timeout="$3"
    
    local result
    result=$(dig @"$server" "$domain" A +time="$timeout" +tries=1 +short 2>/dev/null)
    
    if [[ -n "$result" && ! "$result" =~ ^";;" ]]; then
        echo "$result" | head -1
        return 0
    fi
    return 1
}

# Test DNS with host
test_dns_host() {
    local server="$1"
    local domain="$2"
    local timeout="$3"
    
    local result
    result=$(host -W "$timeout" "$domain" "$server" 2>/dev/null)
    
    if [[ $? -eq 0 && "$result" =~ "has address" ]]; then
        echo "$result" | grep "has address" | head -1 | awk '{print $NF}'
        return 0
    fi
    return 1
}

# Test DNS with nslookup
test_dns_nslookup() {
    local server="$1"
    local domain="$2"
    local timeout="$3"
    
    local result
    # nslookup timeout is limited, use shell timeout if available
    if command -v timeout &>/dev/null; then
        result=$(timeout "$timeout" nslookup "$domain" "$server" 2>/dev/null)
    elif command -v gtimeout &>/dev/null; then
        result=$(gtimeout "$timeout" nslookup "$domain" "$server" 2>/dev/null)
    else
        result=$(nslookup "$domain" "$server" 2>/dev/null)
    fi
    
    if [[ $? -eq 0 && "$result" =~ "Address:" ]]; then
        # Get address after "Name:" section (skip server's address)
        echo "$result" | awk '/^Name:/{found=1} found && /^Address:/{print $2; exit}'
        return 0
    fi
    return 1
}

# Main DNS test function - uses detected tool
test_dns_server() {
    local server="$1"
    local domain="$2"
    local timeout="$3"
    local dns_tool="$4"
    
    local start_time end_time response_time resolved_ip
    
    start_time=$(get_time_ms)
    
    case "$dns_tool" in
        dig)
            resolved_ip=$(test_dns_dig "$server" "$domain" "$timeout")
            ;;
        host)
            resolved_ip=$(test_dns_host "$server" "$domain" "$timeout")
            ;;
        nslookup)
            resolved_ip=$(test_dns_nslookup "$server" "$domain" "$timeout")
            ;;
        *)
            echo "FAIL|0|No DNS tool available"
            return 1
            ;;
    esac
    
    local status=$?
    end_time=$(get_time_ms)
    response_time=$((end_time - start_time))
    
    if [[ $status -eq 0 && -n "$resolved_ip" ]]; then
        echo "OK|$response_time|$resolved_ip"
        return 0
    else
        echo "FAIL|$response_time|timeout/error"
        return 1
    fi
}

# ==============================================================================
# File Operations
# ==============================================================================

# Extract all unique IPv4 addresses from file
extract_ips() {
    local file="$1"
    
    if [[ ! -f "$file" ]]; then
        echo ""
        return 1
    fi
    
    # Extract IPv4 addresses using grep with extended regex
    # Use simpler pattern that works on both Linux and macOS
    grep -Eo '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' "$file" 2>/dev/null | \
        # Validate each IP (each octet 0-255) and deduplicate
        awk -F. '
            $1 >= 0 && $1 <= 255 && 
            $2 >= 0 && $2 <= 255 && 
            $3 >= 0 && $3 <= 255 && 
            $4 >= 0 && $4 <= 255 && 
            !seen[$0]++ { print }
        '
}

# Create sample DNS servers file
create_sample_file() {
    cat > "$INPUT_FILE" << 'EOF'
1.1.1.1
1.0.0.1
8.8.8.8
8.8.4.4
9.9.9.9
208.67.222.222
208.67.220.220
4.2.2.1
4.2.2.2
EOF
    echo "Created sample $INPUT_FILE with 9 servers"
}

# Write header to output file
write_header() {
    local domain="$1"
    local timestamp
    timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    
    cat > "$OUTPUT_FILE" << EOF
# Working DNS servers - Tested: $timestamp
# Test domain: $domain
# Format: IP (response_time_ms)
EOF
}

# Append working server to output (thread-safe with flock if available)
save_working_server() {
    local server="$1"
    local response_time="$2"
    
    if command -v flock &>/dev/null; then
        flock -x "$OUTPUT_FILE" -c "echo '$server (${response_time}ms)' >> '$OUTPUT_FILE'"
    else
        echo "$server (${response_time}ms)" >> "$OUTPUT_FILE"
    fi
}

# ==============================================================================
# User Input Functions
# ==============================================================================

get_worker_count() {
    echo "" >&2
    echo "Workers (parallel tests, default: $DEFAULT_WORKERS, max: 500):" >&2
    echo "  Enter number (1-500) or press Enter for $DEFAULT_WORKERS" >&2
    read -rp "Workers: " choice
    
    if [[ -z "$choice" ]]; then
        echo "$DEFAULT_WORKERS"
        return
    fi
    
    if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= 500 )); then
        echo "$choice"
    else
        echo "Invalid! Using default: $DEFAULT_WORKERS" >&2
        echo "$DEFAULT_WORKERS"
    fi
}

get_timeout() {
    echo "" >&2
    echo "Timeout per test (seconds, default: $DEFAULT_TIMEOUT, range: 1-10):" >&2
    echo "  Enter number (1-10) or press Enter for $DEFAULT_TIMEOUT" >&2
    read -rp "Timeout: " choice
    
    if [[ -z "$choice" ]]; then
        echo "$DEFAULT_TIMEOUT"
        return
    fi
    
    if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= 10 )); then
        echo "$choice"
    else
        echo "Invalid! Using default: $DEFAULT_TIMEOUT" >&2
        echo "$DEFAULT_TIMEOUT"
    fi
}

get_test_domain() {
    local domains=("google.com" "cloudflare.com" "example.com")
    
    echo "" >&2
    echo "Test domains (enter number 1-3 or type domain):" >&2
    echo "  1. google.com" >&2
    echo "  2. cloudflare.com" >&2
    echo "  3. example.com" >&2
    echo "  or type your own domain" >&2
    read -rp "Enter choice (1-3 or domain): " choice
    
    if [[ -z "$choice" ]]; then
        echo "google.com"
        return
    fi
    
    case "$choice" in
        1) echo "google.com" ;;
        2) echo "cloudflare.com" ;;
        3) echo "example.com" ;;
        *)
            if [[ "$choice" =~ \. && ! "$choice" =~ ^https?:// ]]; then
                echo "$choice"
            else
                echo "Invalid! Using default: google.com" >&2
                echo "google.com"
            fi
            ;;
    esac
}

# ==============================================================================
# Main Testing Function
# ==============================================================================

main() {
    echo "Azadi DNS Tester (Bash Edition)"
    echo "======================================================================"
    
    # Detect DNS tool
    local dns_tool
    dns_tool=$(detect_dns_tool)
    
    if [[ -z "$dns_tool" ]]; then
        echo -e "${RED}ERROR: No DNS lookup tool found (dig, host, or nslookup required)${NC}"
        exit 1
    fi
    echo -e "DNS tool: ${CYAN}$dns_tool${NC}"
    
    # Check timing precision
    if has_perl_hires; then
        echo -e "Timing: ${CYAN}High precision (perl Time::HiRes)${NC}"
    elif [[ "$(uname)" == "Linux" ]]; then
        echo -e "Timing: ${CYAN}High precision (date +%s%N)${NC}"
    else
        echo -e "Timing: ${YELLOW}Low precision (second-level)${NC}"
    fi
    
    # Load servers
    if [[ ! -f "$INPUT_FILE" ]]; then
        echo "$INPUT_FILE not found. Creating sample file..."
        create_sample_file
    fi
    
    # Extract unique IPs into array (portable - works with Bash 3.x)
    local servers=()
    while IFS= read -r ip; do
        servers+=("$ip")
    done < <(extract_ips "$INPUT_FILE")
    local total_servers=${#servers[@]}
    
    if [[ $total_servers -eq 0 ]]; then
        echo -e "${RED}No valid IPv4 addresses found in $INPUT_FILE${NC}"
        exit 1
    fi
    
    local total_raw
    total_raw=$(grep -Eo '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' "$INPUT_FILE" 2>/dev/null | wc -l | tr -d ' ')
    echo "Extracted $total_servers UNIQUE IPv4 addresses from $INPUT_FILE"
    echo "Total IPs found (with duplicates): $total_raw"
    echo "UNIQUE IPs: $total_servers"
    
    # Get user configuration
    local workers timeout domain
    workers=$(get_worker_count)
    timeout=$(get_timeout)
    domain=$(get_test_domain)
    
    # Write header
    write_header "$domain"
    
    echo ""
    echo "Starting test of $total_servers DNS servers"
    echo "Config: Workers=$workers | Timeout=${timeout}s | Domain=$domain"
    echo "Working servers will be SAVED IMMEDIATELY as found!"
    echo "----------------------------------------------------------------------"
    
    local start_time working_count=0 failed_count=0
    start_time=$(date +%s)
    
    # Arrays to store results for sorting
    declare -a working_servers
    declare -a working_times
    
    # Temporary file for collecting results
    local temp_results
    temp_results=$(mktemp)
    trap "rm -f '$temp_results'" EXIT
    
    echo "Testing servers..."
    
    # Write servers to file for processing
    local servers_file
    servers_file=$(mktemp)
    printf '%s\n' "${servers[@]}" > "$servers_file"
    
    # Create a standalone worker script that doesn't rely on exported functions
    local worker_script
    worker_script=$(mktemp)
    cat > "$worker_script" << 'WORKERSCRIPT'
#!/bin/bash
server="$1"
domain="$2"
timeout="$3"
dns_tool="$4"
output_file="$5"

# Get time in ms
get_time_ms() {
    if perl -MTime::HiRes -e '1' 2>/dev/null; then
        perl -MTime::HiRes=time -e 'printf "%.0f\n", time * 1000'
    elif [[ "$(uname)" == "Linux" ]]; then
        echo $(($(date +%s%N) / 1000000))
    else
        echo $(($(date +%s) * 1000))
    fi
}

# Test with dig
test_dig() {
    local result
    result=$(dig @"$server" "$domain" A +time="$timeout" +tries=1 +short 2>/dev/null)
    if [[ -n "$result" && ! "$result" =~ ^";;" ]]; then
        echo "$result" | head -1
        return 0
    fi
    return 1
}

# Test with host  
test_host() {
    local result
    result=$(host -W "$timeout" "$domain" "$server" 2>/dev/null)
    if [[ $? -eq 0 && "$result" =~ "has address" ]]; then
        echo "$result" | grep "has address" | head -1 | awk '{print $NF}'
        return 0
    fi
    return 1
}

# Test with nslookup
test_nslookup() {
    local result
    if command -v timeout &>/dev/null; then
        result=$(timeout "$timeout" nslookup "$domain" "$server" 2>/dev/null)
    else
        result=$(nslookup "$domain" "$server" 2>/dev/null)
    fi
    if [[ $? -eq 0 && "$result" =~ "Address:" ]]; then
        echo "$result" | awk '/^Name:/{found=1} found && /^Address:/{print $2; exit}'
        return 0
    fi
    return 1
}

start_time=$(get_time_ms)

case "$dns_tool" in
    dig) resolved_ip=$(test_dig) ;;
    host) resolved_ip=$(test_host) ;;
    nslookup) resolved_ip=$(test_nslookup) ;;
esac
status=$?

end_time=$(get_time_ms)
response_time=$((end_time - start_time))

if [[ $status -eq 0 && -n "$resolved_ip" ]]; then
    echo "$server (${response_time}ms)" >> "$output_file"
    # Print to stderr for real-time display (green)
    echo -e "\033[32m[OK]\033[0m $server (${response_time}ms) -> $resolved_ip" >&2
    echo "OK|$server|$response_time|$resolved_ip"
else
    # Print to stderr for real-time display (red)
    echo -e "\033[31m[FAIL]\033[0m $server" >&2
    echo "FAIL|$server|$response_time"
fi
WORKERSCRIPT
    chmod +x "$worker_script"
    
    # Start progress monitor in background (writes to stderr)
    (
        prev_count=0
        while true; do
            if [[ -f "$temp_results" ]]; then
                done_count=$(wc -l < "$temp_results" 2>/dev/null | tr -d ' ' || echo 0)
                done_count=${done_count:-0}
                working=$(grep -c "^OK|" "$temp_results" 2>/dev/null || echo 0)
                working=${working:-0}
                if [[ $total_servers -gt 0 ]]; then
                    pct=$((done_count * 100 / total_servers))
                else
                    pct=0
                fi
                # Print progress update every 5 seconds
                if [[ "$done_count" -ge "$((prev_count + 50))" ]] || \
                   [[ "$done_count" == "$total_servers" && "$prev_count" != "$done_count" ]]; then
                    echo "--- Progress: $done_count/$total_servers ($pct%) | Working: $working ---" >&2
                    prev_count=$done_count
                fi
            fi
            sleep 1
        done
    ) &
    local monitor_pid=$!
    
    # Run DNS tests in parallel using xargs
    cat "$servers_file" | xargs -P "$workers" -I{} "$worker_script" "{}" "$domain" "$timeout" "$dns_tool" "$OUTPUT_FILE" >> "$temp_results"
    
    # Stop progress monitor
    kill $monitor_pid 2>/dev/null
    wait $monitor_pid 2>/dev/null
    
    # Final summary
    local final_count
    final_count=$(wc -l < "$temp_results" 2>/dev/null | tr -d ' ' || echo 0)
    final_count=${final_count:-0}
    local final_working
    final_working=$(grep -c "^OK|" "$temp_results" 2>/dev/null || echo 0)
    final_working=${final_working:-0}
    echo ""
    echo "=== Completed: $final_count/$total_servers | Working: $final_working ==="
    
    rm -f "$servers_file" "$worker_script"
    
    echo ""
    echo "Processing results..."
    
    # Process results (already printed in real-time, just count and collect for sorting)
    while IFS='|' read -r status server response_time extra; do
        if [[ "$status" == "OK" ]]; then
            ((working_count++))
            working_servers+=("$server")
            working_times+=("$response_time")
        else
            ((failed_count++))
        fi
    done < "$temp_results"
    
    local end_time elapsed success_rate
    end_time=$(date +%s)
    elapsed=$((end_time - start_time))
    
    if (( total_servers > 0 )); then
        success_rate=$(echo "scale=1; $working_count * 100 / $total_servers" | bc)
    else
        success_rate="0.0"
    fi
    
    # Print summary
    echo ""
    echo "======================================================================"
    echo "DNS SERVER TEST RESULTS"
    echo "======================================================================"
    echo "Total servers tested: $total_servers"
    echo "Working servers:      $working_count ($success_rate%)"
    echo "Failed servers:       $failed_count"
    echo "Test duration:        ${elapsed} seconds"
    echo "Test domain:          $domain"
    echo ""
    
    if (( working_count > 0 )); then
        echo "TOP 5 FASTEST SERVERS:"
        
        # Sort and display top 5 using temp file to avoid broken pipe
        local sort_file
        sort_file=$(mktemp)
        for i in "${!working_servers[@]}"; do
            echo "${working_servers[$i]}	${working_times[$i]}"
        done > "$sort_file"
        
        sort -t'	' -k2 -n "$sort_file" | head -5 | \
            awk -F'	' '{printf "  %d. %-15s %sms\n", NR, $1, $2}'
        
        rm -f "$sort_file"
        
        if (( working_count > 5 )); then
            echo "  ... $((working_count - 5)) more servers"
        fi
        echo ""
    fi
    
    echo "Results saved: $OUTPUT_FILE ($working_count servers)"
    echo "======================================================================"
    echo ""
    echo "Testing complete!"
}

# Run main function
main "$@"
