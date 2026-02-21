#!/usr/bin/env python3
import os
import sys
import time
import json
import argparse
import subprocess
import requests
import psutil

# Configuration
LLAMA_SERVER_BIN = os.path.expanduser("~/github/llama.cpp/build/bin/llama-server")
MODEL_PATH = os.path.expanduser("~/llms/qwen3/coder-next-no-bf16/Qwen3-Coder-Next-Q8_0-00001-of-00004.gguf")
LLAMA_URL = "http://localhost:8080"
DEFAULT_MAX_TOKENS = -1

SYSTEM_PROMPT = (
    "You are a meeting notes assistant. Produce detailed, thorough meeting notes — not a concise summary. "
    "Include all topics discussed, decisions made, action items, who said what, and any context or nuance mentioned. "
    "Use markdown formatting with headers and bullet points. Include quotes and excerpts."
)

USER_PROMPT_PREFIX = (
    "Here is the full transcript of a meeting. Write detailed meeting notes covering every topic, "
    "decision, action item, and important details discussed. Include interesting quotes and key excerpts."
)

def is_server_running(url):
    """Check if the server is responding to API requests."""
    try:
        response = requests.get(f"{url}/v1/models", timeout=2)
        return response.status_code == 200
    except requests.exceptions.RequestException:
        return False

def is_process_running(name):
    """Check if a process with the given name exists."""
    for proc in psutil.process_iter(['name']):
        if proc.info['name'] == name:
            return True
    return False

def start_server():
    """Start the llama-server in the background if it's not already running."""
    if is_server_running(LLAMA_URL):
        print("✅ Llama-server is already running and responding.")
        return True

    if is_process_running("llama-server"):
        print("⏳ Llama-server process is running but not responding yet. Waiting...")
    else:
        print("🚀 Llama-server is not running. Starting it now...")
        cmd = [
            LLAMA_SERVER_BIN,
            "-m", MODEL_PATH,
            "-ngl", "999",
            "-c", "131072",
            "-fa", "on",
            "-ctk", "q8_0",
            "-ctv", "q8_0",
            "--no-mmap",
            "--temp", "0"
        ]
        
        # We use Popen to start it in the background
        # We redirect stdout/stderr to a log file or null to avoid cluttering our output
        log_path = "/tmp/llama-server.log"
        print(f"📡 Command issued: {' '.join(cmd)}")
        print(f"📝 Logs are being written to {log_path}")
        
        try:
            log_file = open(log_path, "a")
            subprocess.Popen(cmd, stdout=log_file, stderr=log_file, start_new_session=True)
        except Exception as e:
            print(f"❌ Error starting llama-server process: {e}")
            return False

    # Polling loop
    print("⌛ Waiting for server to become ready (this may take a minute for a 26GB model)...")
    start_time = time.time()
    while time.time() - start_time < 300:  # 5 minute timeout
        if is_server_running(LLAMA_URL):
            print("\n✅ Llama-server is ready!")
            return True
        print(".", end="", flush=True)
        time.sleep(2)
    
    print("\n❌ Error: Timeout waiting for llama-server to start.")
    return False

def generate_summary(transcript_path, output_path, max_tokens, url):
    """Send the transcript to the server and stream the response."""
    if not os.path.exists(transcript_path):
        print(f"❌ Error: File not found: {transcript_path}")
        return

    with open(transcript_path, 'r') as f:
        transcript = f.read()

    print(f"📖 Read transcript from {transcript_path} ({len(transcript)} characters)")
    print(f"📝 Generating meeting notes → {output_path}")
    print(f"💡 To follow the output in another terminal, use: tail -f '{output_path}'")
    print("-" * 40)

    payload = {
        "model": "qwen3",
        "messages": [
            {"role": "system", "content": SYSTEM_PROMPT},
            {"role": "user", "content": f"{USER_PROMPT_PREFIX}\n\n{transcript}"}
        ],
        "max_tokens": max_tokens,
        "temperature": 0,
        "stream": True
    }

    try:
        response = requests.post(
            f"{url}/v1/chat/completions",
            headers={"Content-Type": "application/json"},
            json=payload,
            stream=True
        )
        response.raise_for_status()

        with open(output_path, 'w') as f_out:
            for line in response.iter_lines():
                if line:
                    decoded_line = line.decode('utf-8')
                    if decoded_line.startswith("data: "):
                        data_str = decoded_line[len("data: "):]
                        if data_str.strip() == "[DONE]":
                            break
                        try:
                            data = json.loads(data_str)
                            content = data['choices'][0]['delta'].get('content', '')
                            if content:
                                print(content, end="", flush=True)
                                f_out.write(content)
                                f_out.flush()
                        except (json.JSONDecodeError, KeyError, IndexError):
                            continue
        print("\n" + "-" * 40)
        print(f"✅ Summary saved to: {output_path}")

        # --- NEW: Create Google Doc ---
        print(f"📁 Creating Google Doc in defensetech account...")
        try:
            # 1. Switch auth to defensetech
            switch_cmd = os.path.expanduser("~/.gemini/switch_auth.sh defensetech")
            subprocess.run(switch_cmd, shell=True, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            
            # 2. Use gemini CLI to create the doc from the file
            # We pass the absolute path to make it easier for the CLI
            abs_output_path = os.path.abspath(output_path)
            gemini_cmd = f"gemini \"Create a Google Doc from the markdown file '{abs_output_path}' using its content. The title should be based on the meeting title in the file.\""
            
            # We run this and show output to the user so they can see progress
            subprocess.run(gemini_cmd, shell=True, check=True)
            print(f"✅ Google Doc creation request sent.")
        except subprocess.CalledProcessError as e:
            print(f"⚠️ Warning: Could not create Google Doc automatically: {e}")

    except requests.exceptions.RequestException as e:
        print(f"\n❌ Error calling llama-server: {e}")

def main():
    parser = argparse.ArgumentParser(description="Generate structured meeting notes using local LLM.")
    parser.add_argument("transcript", help="Path to the transcript text file.")
    parser.add_argument("output", nargs="?", help="Path to the output markdown file (default: transcript.txt.md).")
    parser.add_argument("--max-tokens", type=int, default=DEFAULT_MAX_TOKENS, help="Max output tokens (default: -1).")
    parser.add_argument("--url", default=LLAMA_URL, help=f"llama-server URL (default: {LLAMA_URL}).")
    
    args = parser.parse_args()

    # Default output path
    if not args.output:
        args.output = args.transcript + ".md"

    # 1. Ensure server is running
    if not start_server():
        sys.exit(1)

    # 2. Generate summary
    generate_summary(args.transcript, args.output, args.max_tokens, args.url)

if __name__ == "__main__":
    main()
