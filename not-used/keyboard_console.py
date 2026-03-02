#!/home/dcar/.local/share/uv/tools/qmk/bin/python
import hid
import time
import sys

def is_console_hid(device_info):
    return device_info['usage_page'] == 0xFF31 and device_info['usage'] == 0x0074

def read_from_device(device):
    while True:
        try:
            # Read 32 bytes (standard packet size for this console)
            data = device.read(32, timeout=1000)
            if data:
                # Decode bytes to string, replace nulls
                text = bytes(data).decode('utf-8', errors='ignore').replace('\x00', '')
                sys.stdout.write(text)
                sys.stdout.flush()
        except KeyboardInterrupt:
            raise
        except Exception as e:
            print(f"Error reading: {e}")
            break

def main():
    print("Looking for QMK Console devices...")
    
    while True:
        try:
            # Enumerate all HID devices
            all_devices = hid.enumerate()
            
            # Filter for console usage
            console_devices = [d for d in all_devices if is_console_hid(d)]
            
            if not console_devices:
                # print("No QMK Console devices found. Retrying...")
                time.sleep(1)
                continue

            # Pick the first one
            target_info = console_devices[0]
            print(f"Connecting to {target_info['manufacturer_string']} {target_info['product_string']}...")

            h = None
            try:
                h = hid.Device(path=target_info['path'])
                
                print("Connected! Press Ctrl+C to exit.")
                print("-" * 20)
                
                read_from_device(h)
                
            except KeyboardInterrupt:
                raise
            except Exception as e:
                print(f"Failed to open/read device: {e}")
            finally:
                try:
                    h.close()
                except:
                    pass
            
            print("Device disconnected or error. Reconnecting...")
            time.sleep(1)

        except KeyboardInterrupt:
            print("\nExiting.")
            break
        except Exception as e:
            print(f"\nUnexpected error in main loop: {e}")
            time.sleep(1)

if __name__ == "__main__":
    main()
