#!/usr/bin/env python3

"""
requires: pip install dnspython tqdm
"""

import re
import os
import sys
import time
import socket
import threading
import dns.resolver
import dns.exception
from tqdm import tqdm
from datetime import datetime
from concurrent.futures import ThreadPoolExecutor, as_completed

file_lock = threading.Lock()

def get_script_dir():
    """get directory where script is located"""
    return os.path.dirname(os.path.abspath(__file__))

def create_sample_servers(filename='dns_servers.txt'):
    """create sample dns servers file if it doesn't exist"""
    filepath = os.path.join(get_script_dir(), filename)
    if os.path.exists(filepath):
        return
    
    sample_servers = [
        "1.1.1.1", "1.0.0.1", "8.8.8.8", "8.8.4.4", "9.9.9.9",
        "208.67.222.222", "208.67.220.220", "4.2.2.1", "4.2.2.2"
    ]
    
    try:
        with open(filepath, 'w') as f:
            for server in sample_servers:
                f.write(f"{server}\n")
        print(f"created sample {filename} with {len(sample_servers)} servers")
    except Exception as e:
        print(f"error creating {filename}: {e}")

def load_servers(filename='dns_servers.txt'):
    """load all ipv4 addresses from file"""
    filepath = os.path.join(get_script_dir(), filename)
    try:
        with open(filepath, 'r', encoding='utf-8', errors='ignore') as f:
            content = f.read()
        
        ip_pattern = re.compile(
            r'\b(?:(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}'
            r'(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\b'
        )
        
        all_ips = ip_pattern.findall(content)
        servers = list(set(all_ips))
        
        print(f"extracted {len(servers)} unique ipv4 addresses from {filepath}")
        print(f"total ips found (with duplicates): {len(all_ips)}")
        
        if not servers:
            print("no valid ipv4 addresses found. creating sample file...")
            create_sample_servers(filename)
            return load_servers(filename)
        
        return servers
        
    except FileNotFoundError:
        print(f"{filepath} not found. creating sample file...")
        create_sample_servers(filename)
        return load_servers(filename)
    except Exception as e:
        print(f"error loading servers: {e}")
        return []

def write_header(test_domain, include_firewall=False):
    """write header to working_dns.txt once before testing"""
    filepath = os.path.join(get_script_dir(), 'working_dns.txt')
    timestamp = datetime.now().strftime("%y-%m-%d %H:%M:%S")
    filter_mode = "including all responses" if include_firewall else "filtering firewall responses"
    
    with file_lock:
        try:
            with open(filepath, 'w') as f:
                f.write(f"# working dns servers - tested: {timestamp}\n")
                f.write(f"# test domain: {test_domain}\n")
                f.write(f"# mode: {filter_mode} - 10.10.34.34, 10.10.34.35, 10.10.34.36\n")
                f.write("# format: ip (response_time_ms) [firewall: fw_ip]\n")
            print("header written to working_dns.txt")
        except Exception as e:
            print(f"header write error: {e}")

def real_time_save(server_info):
    """thread-safe real-time save of working servers (append only)"""
    filepath = os.path.join(get_script_dir(), 'working_dns.txt')
    
    with file_lock:
        try:
            with open(filepath, 'a') as f:
                f.write(f"{server_info}\n")
        except Exception as e:
            print(f"real-time save error: {e}")

def get_worker_count():
    """get worker count from user with validation"""
    while True:
        try:
            print("\nworkers (parallel tests, default: 100, max: 500):")
            print("  enter number (1-500) or press enter for 100")
            choice = input("workers: ").strip()
            
            if not choice:
                return 100
            workers = int(choice)
            if 1 <= workers <= 500:
                return workers
            else:
                print("invalid! use 1-500")
        except ValueError:
            print("invalid! enter a number")

def get_timeout():
    """get timeout from user with validation"""
    while True:
        try:
            print("\ntimeout per test (seconds, default: 3, range: 1-10):")
            print("  enter number (1-10) or press enter for 3")
            choice = input("timeout: ").strip()
            
            if not choice:
                return 3
            timeout = int(choice)
            if 1 <= timeout <= 10:
                return timeout
            else:
                print("invalid! use 1-10 seconds")
        except ValueError:
            print("invalid! enter a number")

def get_filter_option():
    """ask user if firewall ips should be included"""
    print("\nfirewall response option:")
    print("1. filter firewall responses (10.10.34.34, 10.10.34.35, 10.10.34.36)")
    print("2. include all responses")
    
    while True:
        choice = input("enter choice (1/2): ").strip()
        if choice == '1': 
            print("✓ filtering firewall responses")
            return False
        if choice == '2': 
            print("✓ including all responses")
            return True
        print("enter 1 or 2")

def get_test_domain():
    """get valid test domain from user with numbered menu"""
    domains = ["google.com", "cloudflare.com", "example.com"]
    
    print("\ntest domains (enter number 1-3 or type domain):")
    for i, domain in enumerate(domains, 1):
        print(f"  {i}. {domain}")
    print("  or type your own domain")
    
    while True:
        choice = input("\nenter choice (1-3 or domain): ").strip()
        
        if choice.isdigit() and 1 <= int(choice) <= 3:
            return domains[int(choice) - 1]
        
        if choice and '.' in choice and not choice.startswith(('http://', 'https://')):
            return choice
        
        if not choice:
            return "google.com"
        
        print("invalid! use 1-3 or valid domain")

def test_single_server(server, domain, timeout=3, include_firewall=False):
    """test single dns server with response time"""
    try:
        socket.inet_aton(server)
    except socket.error:
        return False, (server, None), f"{server} invalid ip"
    
    start_time = time.time()
    resolver = dns.resolver.Resolver(configure=False)
    resolver.nameservers = [server]
    resolver.timeout = timeout
    resolver.lifetime = timeout
    
    try:
        answers = resolver.resolve(domain, 'A')
        response_time = (time.time() - start_time) * 1000
        
        firewall_ips = {'10.10.34.34', '10.10.34.35', '10.10.34.36'}
        returned_ips = [str(answer) for answer in answers]
        firewall_found = any(ip in firewall_ips for ip in returned_ips)
        
        first_ip = str(answers[0])
        
        if firewall_found:
            first_fw = next(ip for ip in returned_ips if ip in firewall_ips)
            
            if include_firewall:
                server_info = f"{server} (firewall:{first_fw}) ({response_time:.0f}ms)"
                real_time_save(server_info)
                return True, (server, response_time), f"{server} firewall blocked {response_time:.0f}ms ({first_fw})"
            else:
                return False, (server, response_time), f"{server} firewall blocked ({first_fw})"
        
        server_info = f"{server} ({first_fw}) ({response_time:.0f}ms)"
        real_time_save(server_info)
        return True, (server, response_time), f"{server} ok {response_time:.0f}ms ({first_ip})"
        
    except dns.resolver.NXDOMAIN:
        response_time = (time.time() - start_time) * 1000
        return False, (server, response_time), f"{server} nxdomain"
    except dns.resolver.Timeout:
        response_time = (time.time() - start_time) * 1000
        return False, (server, response_time), f"{server} timeout"
    except dns.resolver.NoAnswer:
        response_time = (time.time() - start_time) * 1000
        return False, (server, response_time), f"{server} no answer"
    except dns.exception.DNSException as e:
        response_time = (time.time() - start_time) * 1000
        return False, (server, response_time), f"{server} dns error"
    except Exception as e:
        response_time = (time.time() - start_time) * 1000
        return False, (server, response_time), f"{server} error"

def check_dns_servers(filename='dns_servers.txt'):
    """main testing function"""
    print("Azadi DNS Tester")
    print("=" * 50)
    
    servers = load_servers(filename)
    if not servers:
        print("no servers to test. exiting.")
        return []
    
    workers = get_worker_count()
    timeout = get_timeout()
    domain = get_test_domain()
    include_firewall = get_filter_option()
    
    write_header(domain, include_firewall)
    
    print(f"\nstarting test of {len(servers)} dns servers")
    print(f"workers={workers} | timeout={timeout}s | domain={domain}")
    print(f"mode: {'including all responses' if include_firewall else 'filtering firewall responses'}")
    print("-" * 50)
    
    start_time = time.time()
    working = []
    failed = []
    
    with ThreadPoolExecutor(max_workers=workers) as executor:
        future_to_server = {
            executor.submit(test_single_server, server, domain, timeout, include_firewall): server 
            for server in servers
        }
        
        with tqdm(total=len(servers), desc="Progress", unit="server", ascii=' █') as pbar:
            for future in as_completed(future_to_server):
                try:
                    success, result, message = future.result()
                    server_ip, response_time = result
                    
                    if success:
                        working.append(result)
                        tqdm.write(f"✅ {message}")
                    else:
                        failed.append(server_ip)
                        tqdm.write(f"❌ {message}")
                except Exception as e:
                    server = future_to_server[future]
                    failed.append(server)
                    tqdm.write(f"❌ crash {server}")
                
                pbar.update(1)
    
    print("\n" + "="*50)
    print("RESULTS")
    print("="*50)
    
    elapsed = time.time() - start_time
    success_rate = (len(working) / len(servers) * 100) if servers else 0
    
    print(f"total tested: {len(servers)}")
    print(f"working: {len(working)} ({success_rate:.1f}%)")
    print(f"failed: {len(failed)}")
    print(f"time: {elapsed:.1f}s")
    
    if working:
        print("\ntop 5 fastest:")
        sorted_working = sorted(working, key=lambda x: x[1])
        for i, (ip, ms) in enumerate(sorted_working[:5], 1):
            print(f"  {i}. {ip:<15} {ms:.0f}ms")
    
    print(f"\nresults saved: working_dns.txt ({len(working)} servers)")
    return working

def main():
    """main entry point"""
    try:
        check_dns_servers()
        print("\nTesting complete!")
        input("Press enter to exit...")
    except KeyboardInterrupt:
        print("\nInterrupted by user")
    except Exception as e:
        print(f"Error: {e}")
        sys.exit(1)

if __name__ == "__main__":
    main()
