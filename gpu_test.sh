#!/bin/bash

# GPU Passthrough Test Function
# Tests GPU hardware acceleration in a VM environment
# Supports NVIDIA (NVENC/NVDEC), AMD (AMF), and Intel (VAAPI/QSV) GPUs

gpu_passthrough_test() {
  local duration=${1:-30}            # Test duration in seconds, default 30
  local resolution=${2:-"1920x1080"} # Test resolution, default 1080p
  local test_dir="$HOME/gpu_test"
  local test_input="$test_dir/test_input.mp4"
  local test_output="$test_dir/test_output.mp4"

  echo "=== GPU Passthrough Test ==="
  echo "Duration: ${duration}s, Resolution: ${resolution}"
  echo "================================"

  # Create test directory
  mkdir -p "$test_dir"
  cd "$test_dir"

  # Function to check if command exists
  command_exists() {
    command -v "$1" >/dev/null 2>&1
  }

  # Check required tools
  echo "🔍 Checking required tools..."
  if ! command_exists ffmpeg; then
    echo "❌ FFmpeg not found! Please install FFmpeg with hardware acceleration support."
    return 1
  fi

  # Detect GPU type and available encoders
  echo "🔍 Detecting GPU and available encoders..."
  ffmpeg -hide_banner -encoders 2>/dev/null | grep -E "(nvenc|amf|vaapi|qsv)" >available_encoders.txt

  # Check actual hardware first, not just FFmpeg encoders
  echo "🔍 Checking actual GPU hardware..."

  # Check for Intel GPU first (most common in VMs)
  if [ -f "/sys/class/drm/card0/device/vendor" ] && grep -q "0x8086" /sys/class/drm/card0/device/vendor 2>/dev/null; then
    GPU_TYPE="INTEL"
    echo "🔵 Intel GPU detected in hardware"

    # Check which Intel encoders are available (prefer VAAPI over QSV)
    if grep -q "h264_vaapi" available_encoders.txt; then
      HW_ENCODER="h264_vaapi"
      HWACCEL="vaapi"
      echo "✅ Using Intel VAAPI (preferred for modern Intel GPUs)"
    elif grep -q "h264_qsv" available_encoders.txt; then
      HW_ENCODER="h264_qsv"
      HWACCEL="qsv"
      echo "✅ Using Intel Quick Sync Video (QSV)"
      echo "💡 Note: VAAPI might work better if QSV fails"
    else
      echo "❌ Intel GPU found but no hardware encoders available in FFmpeg"
      echo "💡 Install Intel VA-API drivers:"
      echo "   sudo apt install intel-media-va-driver-non-free"
      echo "   sudo apt install i965-va-driver  # For older Intel GPUs"
      echo "   sudo apt install vainfo intel-gpu-tools"
      return 1
    fi

  # Check for NVIDIA
  elif command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi >/dev/null 2>&1; then
    GPU_TYPE="NVIDIA"
    HW_ENCODER="h264_nvenc"
    HW_DECODER="h264_cuvid"
    HWACCEL="cuda"
    echo "🟢 NVIDIA GPU detected - using NVENC/NVDEC"

  # Check for AMD
  elif [ -d "/sys/class/drm" ] && find /sys/class/drm/card*/device/vendor -exec grep -l "0x1002" {} \; 2>/dev/null | head -1; then
    GPU_TYPE="AMD"
    HW_ENCODER="h264_amf"
    HW_DECODER=""
    HWACCEL="auto"
    echo "🔴 AMD GPU detected - using AMF"

  # Fallback to encoder detection
  elif grep -q "nvenc" available_encoders.txt; then
    GPU_TYPE="NVIDIA"
    HW_ENCODER="h264_nvenc"
    HW_DECODER="h264_cuvid"
    HWACCEL="cuda"
    echo "⚠️  NVIDIA encoders detected (but may not be working)"
  elif grep -q "amf" available_encoders.txt; then
    GPU_TYPE="AMD"
    HW_ENCODER="h264_amf"
    HW_DECODER=""
    HWACCEL="auto"
    echo "⚠️  AMD encoders detected (but may not be working)"
  elif grep -q -E "(vaapi|qsv)" available_encoders.txt; then
    GPU_TYPE="INTEL"
    if grep -q "h264_qsv" available_encoders.txt; then
      HW_ENCODER="h264_qsv"
      HWACCEL="qsv"
      echo "⚠️  Intel QSV encoders detected (but hardware not confirmed)"
    else
      HW_ENCODER="h264_vaapi"
      HWACCEL="vaapi"
      echo "⚠️  Intel VAAPI encoders detected (but hardware not confirmed)"
    fi
  else
    echo "❌ No hardware acceleration support detected!"
    echo "Available encoders:"
    cat available_encoders.txt
    echo ""
    echo "💡 For Intel GPUs, install: intel-media-driver intel-media-va-driver"
    echo "💡 Check if /dev/dri/renderD128 exists and is accessible"
    return 1
  fi

  # Show DRI devices for debugging
  echo "📋 Available DRI devices:"
  ls -la /dev/dri/ 2>/dev/null || echo "   No DRI devices found"

  # Check for downloaded high-bitrate test videos first
  echo "🔍 Looking for high-bitrate test videos..."
  high_bitrate_videos=(
    "jellyfish-80-mbps-hd-h264.mkv"
    "jellyfish-50-mbps-hd-h264.mkv"
    "jellyfish-120-mbps-4k-uhd-h264.mkv"
    "jellyfish-140-mbps-4k-uhd-h264.mkv"
    "bbb-4k-60fps.mp4"
    "bbb-1080p-60fps.mp4"
  )

  found_video=""
  for video in "${high_bitrate_videos[@]}"; do
    if [ -f "$test_dir/$video" ]; then
      found_video="$test_dir/$video"
      echo "✅ Found high-bitrate test video: $video ($(du -h "$found_video" | cut -f1))"
      echo "   This will provide much better GPU testing than generated content!"
      test_input="$found_video"
      break
    fi
  done

  # Generate test input video if no high-bitrate video found
  if [ -z "$found_video" ] && [ ! -f "$test_input" ]; then
    echo "📹 No high-bitrate test videos found. Generating test video (${duration}s, ${resolution})..."
    echo "💡 Tip: Run 'download_test_videos' first to get better test files!"
    ffmpeg -hide_banner -loglevel error \
      -f lavfi -i "testsrc2=duration=${duration}:size=${resolution}:rate=30" \
      -f lavfi -i "sine=frequency=1000:duration=${duration}" \
      -c:v libx264 -preset fast -crf 23 \
      -c:a aac -b:a 128k \
      "$test_input"

    if [ $? -ne 0 ]; then
      echo "❌ Failed to generate test video"
      return 1
    fi
    echo "✅ Test video generated: $(du -h "$test_input" | cut -f1)"
    echo "⚠️  Generated video may not stress test GPU as much as high-bitrate videos"
  elif [ -z "$found_video" ]; then
    echo "✅ Using existing test video: $(du -h "$test_input" | cut -f1)"
  fi

  # Function to start GPU monitoring in background
  start_gpu_monitoring() {
    case $GPU_TYPE in
    "NVIDIA")
      if command_exists nvidia-smi; then
        echo "📊 Starting NVIDIA GPU monitoring..."
        nvidia-smi pmon -d 1 -c 99999 >gpu_monitor.log 2>&1 &
        GPU_MONITOR_PID=$!
      elif command_exists nvtop; then
        echo "📊 Starting nvtop monitoring..."
        nvtop -d 1 >gpu_monitor.log 2>&1 &
        GPU_MONITOR_PID=$!
      fi
      ;;
    "AMD")
      if command_exists radeontop; then
        echo "📊 Starting AMD GPU monitoring..."
        radeontop -d - >gpu_monitor.log 2>&1 &
        GPU_MONITOR_PID=$!
      fi
      ;;
    "INTEL")
      if command_exists intel_gpu_top; then
        echo "📊 Starting Intel GPU monitoring..."
        intel_gpu_top >gpu_monitor.log 2>&1 &
        GPU_MONITOR_PID=$!
      fi
      ;;
    esac
  }

  # Function to stop GPU monitoring
  stop_gpu_monitoring() {
    if [ ! -z "$GPU_MONITOR_PID" ]; then
      kill $GPU_MONITOR_PID 2>/dev/null
      wait $GPU_MONITOR_PID 2>/dev/null
    fi
  }

  # Test 1: Hardware Decoding + Software Encoding (baseline)
  echo ""
  echo "🧪 Test 1: Hardware Decoding + Software Encoding"
  echo "================================================"

  start_gpu_monitoring

  time_start=$(date +%s)
  if [ "$GPU_TYPE" = "NVIDIA" ]; then
    ffmpeg -hide_banner -loglevel info \
      -hwaccel $HWACCEL -hwaccel_output_format cuda \
      -i "$test_input" \
      -c:v libx264 -preset fast -crf 23 \
      -c:a copy \
      -y "${test_output}_hw_decode.mp4" 2>&1 | tee test1.log
  else
    ffmpeg -hide_banner -loglevel info \
      -hwaccel $HWACCEL \
      -i "$test_input" \
      -c:v libx264 -preset fast -crf 23 \
      -c:a copy \
      -y "${test_output}_hw_decode.mp4" 2>&1 | tee test1.log
  fi
  test1_result=$?
  time_end=$(date +%s)
  test1_time=$((time_end - time_start))

  stop_gpu_monitoring
  mv gpu_monitor.log test1_gpu.log 2>/dev/null

  # Test 2: Hardware Encoding
  echo ""
  echo "🧪 Test 2: Hardware Encoding"
  echo "============================="

  start_gpu_monitoring

  time_start=$(date +%s)
  case $GPU_TYPE in
  "NVIDIA")
    ffmpeg -hide_banner -loglevel info \
      -hwaccel $HWACCEL -hwaccel_output_format cuda \
      -i "$test_input" \
      -c:v $HW_ENCODER -preset fast -b:v 5M \
      -c:a copy \
      -y "${test_output}_hw_encode.mp4" 2>&1 | tee test2.log
    ;;
  "AMD")
    ffmpeg -hide_banner -loglevel info \
      -i "$test_input" \
      -c:v $HW_ENCODER -b:v 5M \
      -c:a copy \
      -y "${test_output}_hw_encode.mp4" 2>&1 | tee test2.log
    ;;
  "INTEL")
    if [ "$HWACCEL" = "vaapi" ]; then
      # VAAPI method
      ffmpeg -hide_banner -loglevel info \
        -hwaccel vaapi -hwaccel_device /dev/dri/renderD128 \
        -i "$test_input" \
        -vf 'format=nv12,hwupload' \
        -c:v h264_vaapi -b:v 5M \
        -c:a copy \
        -y "${test_output}_hw_encode.mp4" 2>&1 | tee test2.log
    else
      # QSV method
      ffmpeg -hide_banner -loglevel info \
        -hwaccel qsv -hwaccel_device /dev/dri/renderD128 \
        -i "$test_input" \
        -c:v h264_qsv -b:v 5M \
        -c:a copy \
        -y "${test_output}_hw_encode.mp4" 2>&1 | tee test2.log

      # If QSV fails, try VAAPI as fallback
      if [ $? -ne 0 ] && grep -q "h264_vaapi" available_encoders.txt; then
        echo "⚠️  QSV failed, trying VAAPI fallback..."
        ffmpeg -hide_banner -loglevel info \
          -hwaccel vaapi -hwaccel_device /dev/dri/renderD128 \
          -i "$test_input" \
          -vf 'format=nv12,hwupload' \
          -c:v h264_vaapi -b:v 5M \
          -c:a copy \
          -y "${test_output}_hw_encode.mp4" 2>&1 | tee test2_vaapi_fallback.log
      fi
    fi
    ;;
  esac
  test2_result=$?
  time_end=$(date +%s)
  test2_time=$((time_end - time_start))

  stop_gpu_monitoring
  mv gpu_monitor.log test2_gpu.log 2>/dev/null

  # Test 3: Full Hardware Pipeline (decode + encode)
  echo ""
  echo "🧪 Test 3: Full Hardware Pipeline"
  echo "=================================="

  start_gpu_monitoring

  time_start=$(date +%s)
  case $GPU_TYPE in
  "NVIDIA")
    ffmpeg -hide_banner -loglevel info \
      -hwaccel $HWACCEL -hwaccel_output_format cuda \
      -i "$test_input" \
      -c:v $HW_ENCODER -preset fast -b:v 5M \
      -c:a copy \
      -y "${test_output}_full_hw.mp4" 2>&1 | tee test3.log
    ;;
  "AMD")
    ffmpeg -hide_banner -loglevel info \
      -hwaccel $HWACCEL \
      -i "$test_input" \
      -c:v $HW_ENCODER -b:v 5M \
      -c:a copy \
      -y "${test_output}_full_hw.mp4" 2>&1 | tee test3.log
    ;;
  "INTEL")
    if [ "$HWACCEL" = "vaapi" ]; then
      # VAAPI method
      ffmpeg -hide_banner -loglevel info \
        -hwaccel vaapi -hwaccel_device /dev/dri/renderD128 \
        -i "$test_input" \
        -vf 'format=nv12,hwupload' \
        -c:v h264_vaapi -b:v 5M \
        -c:a copy \
        -y "${test_output}_full_hw.mp4" 2>&1 | tee test3.log
    else
      # QSV method with VAAPI fallback
      ffmpeg -hide_banner -loglevel info \
        -hwaccel qsv -hwaccel_device /dev/dri/renderD128 \
        -i "$test_input" \
        -c:v h264_qsv -b:v 5M \
        -c:a copy \
        -y "${test_output}_full_hw.mp4" 2>&1 | tee test3.log

      # If QSV fails, try VAAPI as fallback
      if [ $? -ne 0 ] && grep -q "h264_vaapi" available_encoders.txt; then
        echo "⚠️  QSV failed, trying VAAPI fallback..."
        ffmpeg -hide_banner -loglevel info \
          -hwaccel vaapi -hwaccel_device /dev/dri/renderD128 \
          -i "$test_input" \
          -vf 'format=nv12,hwupload' \
          -c:v h264_vaapi -b:v 5M \
          -c:a copy \
          -y "${test_output}_full_hw.mp4" 2>&1 | tee test3_vaapi_fallback.log
      fi
    fi
    ;;
  esac
  test3_result=$?
  time_end=$(date +%s)
  test3_time=$((time_end - time_start))

  stop_gpu_monitoring
  mv gpu_monitor.log test3_gpu.log 2>/dev/null

  # Test 4: Software-only baseline for comparison
  echo ""
  echo "🧪 Test 4: Software-only Baseline"
  echo "=================================="

  time_start=$(date +%s)
  ffmpeg -hide_banner -loglevel error \
    -i "$test_input" \
    -c:v libx264 -preset fast -crf 23 \
    -c:a copy \
    -y "${test_output}_software.mp4" 2>&1
  test4_result=$?
  time_end=$(date +%s)
  test4_time=$((time_end - time_start))

  # Display results
  echo ""
  echo "📊 TEST RESULTS"
  echo "==============="
  printf "%-30s %-10s %-10s\n" "Test" "Status" "Time (s)"
  printf "%-30s %-10s %-10s\n" "----" "------" "--------"

  [ $test1_result -eq 0 ] && status1="✅ PASS" || status1="❌ FAIL"
  [ $test2_result -eq 0 ] && status2="✅ PASS" || status2="❌ FAIL"
  [ $test3_result -eq 0 ] && status3="✅ PASS" || status3="❌ FAIL"
  [ $test4_result -eq 0 ] && status4="✅ PASS" || status4="❌ FAIL"

  printf "%-30s %-10s %-10s\n" "Hardware Decode" "$status1" "$test1_time"
  printf "%-30s %-10s %-10s\n" "Hardware Encode" "$status2" "$test2_time"
  printf "%-30s %-10s %-10s\n" "Full Hardware Pipeline" "$status3" "$test3_time"
  printf "%-30s %-10s %-10s\n" "Software Baseline" "$status4" "$test4_time"

  # Performance analysis
  echo ""
  echo "📈 PERFORMANCE ANALYSIS"
  echo "======================="

  if [ $test3_result -eq 0 ] && [ $test4_result -eq 0 ]; then
    speedup=$(echo "scale=2; $test4_time / $test3_time" | bc 2>/dev/null || echo "N/A")
    echo "Hardware speedup: ${speedup}x faster than software"

    if [ "$speedup" != "N/A" ] && (($(echo "$speedup > 1.5" | bc -l 2>/dev/null || echo 0))); then
      echo "✅ Significant performance improvement detected!"
    elif [ "$speedup" != "N/A" ] && (($(echo "$speedup > 1.0" | bc -l 2>/dev/null || echo 0))); then
      echo "⚠️  Modest performance improvement detected."
    else
      echo "❌ No significant performance improvement. Check GPU passthrough configuration."
    fi
  fi

  # Check for hardware acceleration indicators in logs
  echo ""
  echo "🔍 HARDWARE ACCELERATION INDICATORS"
  echo "==================================="

  case $GPU_TYPE in
  "NVIDIA")
    if grep -q "cuda" test2.log && grep -q "nvenc" test2.log; then
      echo "✅ NVIDIA CUDA and NVENC detected in logs"
    else
      echo "❌ NVIDIA hardware acceleration not confirmed in logs"
    fi
    ;;
  "AMD")
    if grep -q "amf" test2.log; then
      echo "✅ AMD AMF detected in logs"
    else
      echo "❌ AMD hardware acceleration not confirmed in logs"
    fi
    ;;
  "INTEL")
    if grep -q "vaapi" test2.log; then
      echo "✅ Intel VAAPI detected in logs"
    else
      echo "❌ Intel hardware acceleration not confirmed in logs"
    fi
    ;;
  esac

  # GPU monitoring results
  if [ -f "test2_gpu.log" ]; then
    echo ""
    echo "📊 GPU UTILIZATION DURING ENCODING"
    echo "=================================="
    echo "Check test2_gpu.log for detailed GPU utilization during hardware encoding"

    case $GPU_TYPE in
    "NVIDIA")
      if grep -q "enc" test2_gpu.log 2>/dev/null; then
        echo "✅ GPU encoder utilization detected"
      fi
      ;;
    esac
  fi

  # Clean up and summary
  echo ""
  echo "📁 TEST FILES LOCATION"
  echo "======================"
  echo "Test directory: $test_dir"
  echo "Generated files:"
  ls -lh "$test_dir"/*.mp4 2>/dev/null | awk '{print "  " $9 " (" $5 ")"}'
  echo ""
  echo "Log files:"
  ls -lh "$test_dir"/*.log 2>/dev/null | awk '{print "  " $9 " (" $5 ")"}'

  # Final verdict
  echo ""
  echo "🏁 FINAL VERDICT"
  echo "================"

  if [ $test2_result -eq 0 ] || [ $test3_result -eq 0 ]; then
    echo "✅ GPU passthrough appears to be working!"
    echo "Hardware encoding completed successfully."
    if command_exists nvtop || command_exists nvidia-smi || command_exists radeontop || command_exists intel_gpu_top; then
      echo "💡 Tip: Run 'nvtop' (NVIDIA), 'radeontop' (AMD), or 'intel_gpu_top' (Intel) in another terminal"
      echo "   while running this test to see real-time GPU utilization."
    fi
  else
    echo "❌ GPU passthrough may not be working correctly."
    echo "Hardware encoding failed. Check your GPU passthrough configuration."
    echo ""
    echo "Troubleshooting tips:"
    echo "1. Ensure GPU is properly passed through to VM"
    echo "2. Install appropriate GPU drivers in VM"
    echo "3. Check if FFmpeg was compiled with hardware acceleration support"
    echo "4. Verify device permissions (e.g., /dev/dri/renderD128 for Intel/AMD)"
  fi

  cd - >/dev/null
}

# Additional utility functions

# Quick GPU info check
gpu_info() {
  echo "=== GPU Information ==="

  # Check for Intel GPU
  if [ -f "/sys/class/drm/card0/device/vendor" ] && grep -q "0x8086" /sys/class/drm/card0/device/vendor 2>/dev/null; then
    echo "🔵 Intel GPU detected"

    # Try to get more Intel GPU info
    if [ -f "/sys/class/drm/card0/device/device" ]; then
      device_id=$(cat /sys/class/drm/card0/device/device 2>/dev/null)
      echo "   Device ID: $device_id"
    fi

    # Check for Intel GPU tools
    if command -v intel_gpu_top >/dev/null 2>&1; then
      echo "   Intel GPU monitoring: intel_gpu_top available ✅"
    else
      echo "   Intel GPU monitoring: intel_gpu_top not found ❌"
      echo "   Install with: sudo apt install intel-gpu-tools"
    fi

    # Check VA-API
    if command -v vainfo >/dev/null 2>&1; then
      echo ""
      echo "VA-API Information:"
      vainfo 2>/dev/null | head -10
    else
      echo "   VA-API info: vainfo not found"
      echo "   Install with: sudo apt install vainfo"
    fi
  fi

  # Check for NVIDIA
  if command -v nvidia-smi >/dev/null 2>&1; then
    echo "🟢 NVIDIA GPU detected:"
    nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv,noheader,nounits 2>/dev/null || echo "   nvidia-smi failed to run"
  fi

  # Check for AMD
  if [ -d "/sys/class/drm" ]; then
    for card in /sys/class/drm/card*/device/vendor; do
      if [ -f "$card" ] && grep -q "0x1002" "$card" 2>/dev/null; then
        echo "🔴 AMD GPU detected"
        break
      fi
    done
  fi

  # Check DRI devices
  echo ""
  echo "DRI devices:"
  if [ -d "/dev/dri" ]; then
    ls -la /dev/dri/ 2>/dev/null
    echo ""
    echo "Permissions check:"
    for device in /dev/dri/renderD*; do
      if [ -e "$device" ]; then
        echo "  $device: $(ls -l "$device" | cut -d' ' -f1,3,4)"
        if [ -r "$device" ] && [ -w "$device" ]; then
          echo "    ✅ Readable and writable by current user"
        else
          echo "    ❌ Not accessible by current user"
          echo "    Try: sudo usermod -a -G render,video $USER"
        fi
      fi
    done
  else
    echo "❌ No DRI devices found"
  fi

  # Check FFmpeg hardware support
  echo ""
  echo "FFmpeg hardware acceleration support:"
  if command -v ffmpeg >/dev/null 2>&1; then
    echo "Hardware acceleration methods:"
    ffmpeg -hide_banner -hwaccels 2>/dev/null
    echo ""
    echo "Available hardware encoders:"
    ffmpeg -hide_banner -encoders 2>/dev/null | grep -E "(vaapi|qsv|nvenc|amf)" || echo "None found"
  else
    echo "FFmpeg not found"
  fi
}

# Download high-bitrate test videos for stress testing
download_test_videos() {
  local test_dir="$HOME/gpu_test"
  mkdir -p "$test_dir"
  cd "$test_dir"

  echo "📥 Downloading high-bitrate test videos for GPU stress testing..."
  echo "These videos will really show the difference between hardware and software processing!"
  echo ""

  # Jellyfish high-bitrate test videos - these are perfect for GPU testing
  declare -A test_videos=(
    # HD High Bitrate Videos (1080p)
    ["jellyfish-50-mbps-hd-h264.mkv"]="https://repo.jellyfin.org/archive/jellyfish/media/jellyfish-50-mbps-hd-h264.mkv"
    ["jellyfish-80-mbps-hd-h264.mkv"]="https://repo.jellyfin.org/archive/jellyfish/media/jellyfish-80-mbps-hd-h264.mkv"
    ["jellyfish-50-mbps-hd-hevc.mkv"]="https://repo.jellyfin.org/archive/jellyfish/media/jellyfish-50-mbps-hd-hevc.mkv"
    ["jellyfish-80-mbps-hd-hevc.mkv"]="https://repo.jellyfin.org/archive/jellyfish/media/jellyfish-80-mbps-hd-hevc.mkv"

    # 4K Ultra High Bitrate Videos - these will crush software decoders!
    ["jellyfish-120-mbps-4k-uhd-h264.mkv"]="https://repo.jellyfin.org/archive/jellyfish/media/jellyfish-120-mbps-4k-uhd-h264.mkv"
    ["jellyfish-140-mbps-4k-uhd-h264.mkv"]="https://repo.jellyfin.org/archive/jellyfish/media/jellyfish-140-mbps-4k-uhd-h264.mkv"
    ["jellyfish-120-mbps-4k-uhd-hevc-10bit.mkv"]="https://repo.jellyfin.org/archive/jellyfish/media/jellyfish-120-mbps-4k-uhd-hevc-10bit.mkv"
    ["jellyfish-140-mbps-4k-uhd-hevc-10bit.mkv"]="https://repo.jellyfin.org/archive/jellyfish/media/jellyfish-140-mbps-4k-uhd-hevc-10bit.mkv"
  )

  # Also add alternative sources
  declare -A alt_videos=(
    # Big Buck Bunny 4K versions
    ["bbb-4k-60fps.mp4"]="https://test-videos.co.uk/bigbuckbunny/mp4-h264/bbb_sunflower_2160p_60fps_normal.mp4"
    ["bbb-1080p-60fps.mp4"]="https://test-videos.co.uk/bigbuckbunny/mp4-h264/bbb_sunflower_1080p_60fps_normal.mp4"
  )

  echo "Available high-bitrate test videos:"
  echo "=================================="
  printf "%-35s %-15s %s\n" "Video File" "Quality" "Purpose"
  printf "%-35s %-15s %s\n" "----------" "-------" "-------"
  printf "%-35s %-15s %s\n" "jellyfish-50-mbps-hd-h264.mkv" "1080p 50Mbps" "High bitrate H.264 test"
  printf "%-35s %-15s %s\n" "jellyfish-80-mbps-hd-h264.mkv" "1080p 80Mbps" "Extreme H.264 test"
  printf "%-35s %-15s %s\n" "jellyfish-120-mbps-4k-uhd-h264.mkv" "4K 120Mbps" "4K H.264 stress test"
  printf "%-35s %-15s %s\n" "jellyfish-140-mbps-4k-uhd-h264.mkv" "4K 140Mbps" "Maximum 4K test"
  printf "%-35s %-15s %s\n" "jellyfish-*-hevc-*.mkv" "Various HEVC" "HEVC/H.265 tests"
  echo ""

  # Download function with progress and error handling
  download_with_progress() {
    local url="$1"
    local filename="$2"
    local description="$3"

    if [ -f "$filename" ]; then
      echo "✅ Already exists: $filename ($(du -h "$filename" | cut -f1))"
      return 0
    fi

    echo "📥 Downloading $description..."
    echo "   File: $filename"
    echo "   URL: $url"

    if command -v wget >/dev/null 2>&1; then
      if wget --progress=bar:force --timeout=30 -c -O "$filename.tmp" "$url" 2>&1; then
        mv "$filename.tmp" "$filename"
        echo "✅ Downloaded: $filename ($(du -h "$filename" | cut -f1))"
        return 0
      fi
    elif command -v curl >/dev/null 2>&1; then
      if curl -L --connect-timeout 30 -C - -o "$filename.tmp" "$url" 2>&1; then
        mv "$filename.tmp" "$filename"
        echo "✅ Downloaded: $filename ($(du -h "$filename" | cut -f1))"
        return 0
      fi
    else
      echo "❌ Neither wget nor curl found. Cannot download test videos."
      return 1
    fi

    echo "❌ Failed to download: $filename"
    rm -f "$filename.tmp"
    return 1
  }

  echo "Select test videos to download:"
  echo "1) Light test (50MB) - 1080p 50Mbps H.264"
  echo "2) Medium test (200MB) - 1080p 80Mbps H.264"
  echo "3) Heavy test (500MB) - 4K 120Mbps H.264"
  echo "4) Extreme test (800MB) - 4K 140Mbps H.264"
  echo "5) HEVC test (200MB) - 1080p 80Mbps HEVC"
  echo "6) All tests (download everything - ~2GB+)"
  echo "7) Quick download - Big Buck Bunny 4K (smaller files)"
  echo ""
  read -p "Choose option (1-7, or Enter for option 2): " choice
  choice=${choice:-2}

  case $choice in
  1)
    download_with_progress "${test_videos["jellyfish-50-mbps-hd-h264.mkv"]}" "jellyfish-50-mbps-hd-h264.mkv" "Light GPU Test (1080p 50Mbps)"
    ;;
  2)
    download_with_progress "${test_videos["jellyfish-80-mbps-hd-h264.mkv"]}" "jellyfish-80-mbps-hd-h264.mkv" "Medium GPU Test (1080p 80Mbps)"
    ;;
  3)
    download_with_progress "${test_videos["jellyfish-120-mbps-4k-uhd-h264.mkv"]}" "jellyfish-120-mbps-4k-uhd-h264.mkv" "Heavy GPU Test (4K 120Mbps)"
    ;;
  4)
    download_with_progress "${test_videos["jellyfish-140-mbps-4k-uhd-h264.mkv"]}" "jellyfish-140-mbps-4k-uhd-h264.mkv" "Extreme GPU Test (4K 140Mbps)"
    ;;
  5)
    download_with_progress "${test_videos["jellyfish-80-mbps-hd-hevc.mkv"]}" "jellyfish-80-mbps-hd-hevc.mkv" "HEVC Test (1080p 80Mbps)"
    ;;
  6)
    echo "Downloading all test videos (this may take a while)..."
    for filename in "${!test_videos[@]}"; do
      download_with_progress "${test_videos[$filename]}" "$filename" "$filename"
    done
    ;;
  7)
    download_with_progress "${alt_videos["bbb-4k-60fps.mp4"]}" "bbb-4k-60fps.mp4" "Big Buck Bunny 4K 60fps"
    download_with_progress "${alt_videos["bbb-1080p-60fps.mp4"]}" "bbb-1080p-60fps.mp4" "Big Buck Bunny 1080p 60fps"
    ;;
  *)
    echo "Invalid choice, downloading medium test..."
    download_with_progress "${test_videos["jellyfish-80-mbps-hd-h264.mkv"]}" "jellyfish-80-mbps-hd-h264.mkv" "Medium GPU Test (1080p 80Mbps)"
    ;;
  esac

  echo ""
  echo "📊 Downloaded test files:"
  ls -lh *.mkv *.mp4 2>/dev/null | awk '{print "  " $9 " (" $5 ")"}'
  echo ""
  echo "💡 Pro tip: The higher bitrate files will show much more dramatic"
  echo "   performance differences between hardware and software processing!"
  echo "   Try the 4K 140Mbps file for the ultimate stress test."

  cd - >/dev/null
}

# Show usage examples
gpu_test_usage() {
  cat <<'EOF'
🚀 GPU Passthrough Test Usage Examples
=====================================

Basic test (30 seconds, 1080p):
    gpu_passthrough_test

Custom duration and resolution:
    gpu_passthrough_test 60 "1920x1080"
    gpu_passthrough_test 10 "3840x2160"

Check GPU information:
    gpu_info

Download high-bitrate test videos for stress testing:
    download_test_videos

💡 IMPORTANT: Download test videos first for best results!
The generated test videos are lightweight. For real GPU stress testing,
download high-bitrate videos that will show dramatic performance differences:

  download_test_videos   # Then select option for your needs
  gpu_passthrough_test   # Will automatically use downloaded videos

Available high-bitrate test options:
- 1080p 50Mbps H.264 (~50MB) - Light stress test
- 1080p 80Mbps H.264 (~200MB) - Medium stress test  
- 4K 120Mbps H.264 (~500MB) - Heavy stress test
- 4K 140Mbps H.264 (~800MB) - Extreme stress test
- HEVC/H.265 variants - Test newer codec support

Monitor GPU during test (run in separate terminal):
    # NVIDIA:
    nvidia-smi pmon -d 1
    nvtop

    # AMD:
    radeontop

    # Intel:
    intel_gpu_top

The test will create files in ~/gpu_test/ including:
- Test input video (or use downloaded high-bitrate videos)
- Encoded output videos
- Log files
- GPU monitoring logs

Look for "✅ GPU passthrough appears to be working!" in the results.

🎯 What makes a good test:
- High-bitrate source videos stress the decoder more
- 4K videos require significantly more GPU power
- HEVC/H.265 videos test newer codec support
- Compare hardware vs software encoding times
EOF
}

# Make functions available when script is sourced
export -f gpu_passthrough_test gpu_info download_test_videos gpu_test_usage

echo "GPU Passthrough Test loaded! Use:"
echo "  gpu_passthrough_test [duration] [resolution]"
echo "  gpu_info"
echo "  gpu_test_usage"
