#!/usr/bin/env python3
"""
Multi-Camera VLM Monitoring System - YOLO26 + VLM VERSION
Real-time AI analysis of 8 CCTV cameras with alert detection

FEATURES:
- VLM analysis on all cameras
- YOLO26n object detection (expanded classes) on configured cameras
- Concurrent processing (all cameras analyzed in parallel)
- Individual camera on/off controls for streaming and analysis
- Real-time detection overlays on video feed
- YOLO detections posted to alerts every minute
"""

import asyncio
import aiohttp
import cv2
import base64
import json
import time
import logging
import os
import hmac
import ipaddress
import secrets
import ssl
from datetime import datetime
from pathlib import Path
from typing import Dict, List, Optional, Tuple
from dataclasses import dataclass, asdict
from urllib.parse import urlsplit
from aiohttp import web
import numpy as np

# YOLO26 for object detection
try:
    from ultralytics import YOLO
    YOLO_AVAILABLE = True
except ImportError:
    YOLO_AVAILABLE = False
    logging.warning("ultralytics not installed. YOLO26 detection will be disabled.")

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)

CAMERA_CONFIG_PATH = Path.home() / "Library/Application Support/MultiCameraVLM/cameras.json"

@dataclass
class CameraConfig:
    """Configuration for a single camera"""
    id: int
    name: str
    rtsp_url: str
    enabled: bool = True
    streaming_enabled: bool = True  # Control streaming separately
    analysis_enabled: bool = True   # Control VLM analysis separately
    yolo_enabled: bool = False      # NEW: Enable YOLOv26 detection
    frame_interval: int = 60
    prompt: str = "Describe any suspicious or unusual activity in this image."
    source_type: str = "rtsp"
    source_label: str = ""


def normalize_rtsp_url(value: str) -> str:
    if not isinstance(value, str):
        raise ValueError("RTSP URL must be text")

    rtsp_url = value.strip()
    try:
        parsed = urlsplit(rtsp_url)
        port = parsed.port
    except ValueError as exc:
        raise ValueError("Enter a valid RTSP URL") from exc

    if parsed.scheme.lower() not in {"rtsp", "rtsps"} or not parsed.hostname:
        raise ValueError("URL must start with rtsp:// or rtsps:// and include a host")
    if port is not None and not 1 <= port <= 65535:
        raise ValueError("RTSP port must be between 1 and 65535")
    if any(character.isspace() for character in rtsp_url):
        raise ValueError("RTSP URL cannot contain spaces")
    if parsed.username is not None or parsed.password is not None:
        raise ValueError("RTSP URL cannot contain credentials; remove the user and password from the URL")

    return rtsp_url


def load_camera_configs() -> List[CameraConfig]:
    if not CAMERA_CONFIG_PATH.exists():
        return []

    try:
        entries = json.loads(CAMERA_CONFIG_PATH.read_text())
        if not isinstance(entries, list):
            raise ValueError("Camera configuration must be a list")

        cameras = []
        used_ids = set()
        for entry in entries:
            try:
                camera_id = int(entry["id"])
                name = str(entry["name"]).strip()
                source_type = str(entry.get("source_type", "rtsp"))
                if source_type not in {"rtsp", "browser"}:
                    continue
                rtsp_url = normalize_rtsp_url(entry.get("rtsp_url", "")) if source_type == "rtsp" else ""
                if camera_id < 1 or camera_id in used_ids or not name:
                    continue
                camera = CameraConfig(
                    id=camera_id,
                    name=name[:80],
                    rtsp_url=rtsp_url,
                    enabled=bool(entry.get("enabled", True)),
                    streaming_enabled=bool(entry.get("streaming_enabled", True)),
                    analysis_enabled=bool(entry.get("analysis_enabled", False)),
                    yolo_enabled=bool(entry.get("yolo_enabled", False)),
                    frame_interval=max(1, min(3600, int(entry.get("frame_interval", 60)))),
                    prompt=str(entry.get("prompt", "Describe any suspicious or unusual activity in this image."))[:2000],
                    source_type=source_type,
                    source_label=str(entry.get("source_label", ""))[:80]
                )
                cameras.append(camera)
                used_ids.add(camera_id)
            except (KeyError, TypeError, ValueError):
                continue
        return cameras
    except (OSError, json.JSONDecodeError, ValueError):
        logger.exception("Could not load camera configuration")
        return []

@dataclass
class YOLODetection:
    """YOLO detection result"""
    class_name: str
    confidence: float
    bbox: Tuple[int, int, int, int]  # x1, y1, x2, y2

@dataclass
class Alert:
    """Alert event"""
    timestamp: str
    camera_id: int
    camera_name: str
    prompt: str
    response: str
    confidence: str
    image_base64: Optional[str] = None
    yolo_summary: Optional[str] = None  # NEW: YOLO detection summary

class YOLODetector:
    """YOLO26 object detector for real-time detection"""
    
    def __init__(self, model_name: str = "yolo26n.pt"):
        """Initialize YOLO detector
        
        Args:
            model_name: Ultralytics YOLO26 checkpoint, such as yolo26n.pt.
        """
        if not YOLO_AVAILABLE:
            raise ImportError("ultralytics package not installed. Run: pip install ultralytics")
        
        logger.info(f"Loading YOLO model: {model_name}")
        self.model = YOLO(model_name)
        
        # UPDATED: Expanded COCO class IDs we care about
        self.target_classes = {
            0: 'person',
            1: 'bicycle',
            2: 'car',
            3: 'motorcycle',
            5: 'bus',
            7: 'truck',
            15: 'cat',
            16: 'dog',
            24: 'backpack',
            26: 'handbag',
            28: 'suitcase',
            67: 'cell phone'
        }
        
        # UPDATED: Colors for bounding boxes (BGR format) - unique color for each class
        self.colors = {
            'person': (0, 255, 0),       # Green
            'bicycle': (255, 200, 0),    # Light Blue
            'car': (255, 0, 0),          # Blue
            'motorcycle': (255, 255, 0), # Cyan
            'bus': (0, 165, 255),        # Orange
            'truck': (0, 0, 255),        # Red
            'cat': (203, 192, 255),      # Pink
            'dog': (147, 20, 255),       # Deep Pink
            'backpack': (180, 105, 255), # Hot Pink
            'handbag': (238, 130, 238),  # Violet
            'suitcase': (211, 0, 148),   # Dark Violet
            'cell phone': (130, 0, 75)   # Navy
        }
        
        logger.info(f"YOLO detector ready. Detecting: {list(self.target_classes.values())}")
    
    def detect(self, frame: np.ndarray, conf_threshold: float = 0.5) -> Tuple[List[YOLODetection], np.ndarray]:
        """Run detection on a frame
        
        Args:
            frame: Input frame (BGR format)
            conf_threshold: Confidence threshold for detections
            
        Returns:
            Tuple of (list of detections, annotated frame)
        """
        # Run inference
        results = self.model(frame, conf=conf_threshold, verbose=False)[0]
        
        detections = []
        annotated_frame = frame.copy()
        
        # Process detections
        for box in results.boxes:
            class_id = int(box.cls[0])
            
            # Only process target classes
            if class_id not in self.target_classes:
                continue
            
            confidence = float(box.conf[0])
            class_name = self.target_classes[class_id]
            
            # Get bounding box coordinates
            x1, y1, x2, y2 = box.xyxy[0].cpu().numpy().astype(int)
            
            # Store detection
            detection = YOLODetection(
                class_name=class_name,
                confidence=confidence,
                bbox=(int(x1), int(y1), int(x2), int(y2))
            )
            detections.append(detection)
            
            # Draw on frame
            color = self.colors.get(class_name, (255, 255, 255))
            
            # Draw bounding box
            cv2.rectangle(annotated_frame, (x1, y1), (x2, y2), color, 2)
            
            # Draw label with background
            label = f"{class_name} {confidence:.2f}"
            label_size, _ = cv2.getTextSize(label, cv2.FONT_HERSHEY_SIMPLEX, 0.6, 2)
            
            # Draw label background
            cv2.rectangle(
                annotated_frame,
                (x1, y1 - label_size[1] - 10),
                (x1 + label_size[0], y1),
                color,
                -1
            )
            
            # Draw label text
            cv2.putText(
                annotated_frame,
                label,
                (x1, y1 - 5),
                cv2.FONT_HERSHEY_SIMPLEX,
                0.6,
                (255, 255, 255),
                2
            )
        
        return detections, annotated_frame

class VLMClient:
    """Client for VLM API (Ollama/vLLM compatible)"""
    
    def __init__(self, api_base: str = "http://localhost:11434/v1", model: str = "gemma3:4b"):
        self.api_base = api_base
        self.model = model
        self.session = None
        
    async def init_session(self):
        """Initialize aiohttp session"""
        if not self.session:
            self.session = aiohttp.ClientSession()
    
    async def close(self):
        """Close aiohttp session"""
        if self.session:
            await self.session.close()
    
    async def analyze_frame(self, frame_base64: str, prompt: str) -> str:
        """Send frame to VLM for analysis"""
        await self.init_session()
        
        url = f"{self.api_base}/chat/completions"
        
        payload = {
            "model": self.model,
            "messages": [
                {
                    "role": "user",
                    "content": [
                        {"type": "text", "text": prompt},
                        {
                            "type": "image_url",
                            "image_url": {"url": f"data:image/jpeg;base64,{frame_base64}"}
                        }
                    ]
                }
            ],
            "max_tokens": 150,
            "temperature": 0.1
        }
        
        try:
            async with self.session.post(url, json=payload, timeout=30) as response:
                if response.status == 200:
                    data = await response.json()
                    return data['choices'][0]['message']['content']
                else:
                    error_text = await response.text()
                    logger.error(f"VLM API error {response.status}: {error_text}")
                    return f"Error: API returned {response.status}"
        except asyncio.TimeoutError:
            logger.error("VLM request timed out")
            return "Error: Request timed out"
        except Exception as e:
            logger.error(f"VLM request failed: {e}")
            return f"Error: {str(e)}"

class CameraStream:
    """Handles individual camera RTSP stream"""
    
    def __init__(self, config: CameraConfig, yolo_detector: Optional[YOLODetector] = None):
        self.config = config
        self.cap = None
        self.frame_count = 0
        self.last_frame = None
        self.last_frame_jpeg = None
        self.last_frame_base64 = None
        self.running = False
        self.grab_task = None
        self._lock = asyncio.Lock()
        
        # YOLO detection support
        self.yolo_detector = yolo_detector
        self.last_detections = []
        self.last_annotated_frame = None
        self.browser_connected = False
        
        # NEW: Track last YOLO alert time for minute-based alerts
        self.last_yolo_alert_time = 0
        
    def start(self):
        """Start camera stream"""
        logger.info(f"Starting camera {self.config.id}: {self.config.name}")
        self.running = True
        if self.config.source_type == "browser":
            return True
        try:
            opened = self._open_capture()
            if not opened:
                logger.warning(f"Camera {self.config.id}: RTSP connection not ready")
            return opened
        except Exception as e:
            logger.error(f"Failed to start camera {self.config.id}: {e}")
            return False

    def _open_capture(self) -> bool:
        if self.cap:
            self.cap.release()

        params = [
            cv2.CAP_PROP_OPEN_TIMEOUT_MSEC, 5000,
            cv2.CAP_PROP_READ_TIMEOUT_MSEC, 5000
        ]
        self.cap = cv2.VideoCapture(self.config.rtsp_url, cv2.CAP_FFMPEG, params)
        self.cap.set(cv2.CAP_PROP_BUFFERSIZE, 1)
        self.cap.set(cv2.CAP_PROP_FPS, 15)
        return self.cap.isOpened()

    def _read_latest_frame(self):
        capture = self.cap
        if not capture or not capture.isOpened():
            return False, None
        for _ in range(5):
            capture.grab()
        return capture.read()
    
    def stop(self):
        """Stop camera stream"""
        self.running = False
        self.browser_connected = False
        if self.cap:
            self.cap.release()
            self.cap = None

    async def receive_browser_frame(self, frame: np.ndarray) -> bool:
        if self.config.source_type != "browser" or not self.running:
            return False

        self.frame_count += 1
        annotated_frame = frame
        if self.config.yolo_enabled and self.yolo_detector and self.frame_count % 2 == 0:
            try:
                detections, annotated_frame = await asyncio.to_thread(self.yolo_detector.detect, frame)
                async with self._lock:
                    self.last_detections = detections
                    self.last_annotated_frame = annotated_frame
            except Exception as exc:
                logger.error(f"YOLO detection error on browser camera {self.config.id}: {exc}")

        async with self._lock:
            self.last_frame = frame
            if self.config.streaming_enabled:
                display_frame = annotated_frame if self.config.yolo_enabled and self.yolo_detector else frame
                encoded, buffer = cv2.imencode(".jpg", display_frame, [cv2.IMWRITE_JPEG_QUALITY, 70])
                self.last_frame_jpeg = buffer.tobytes() if encoded else None
        return True

    async def set_browser_connected(self, connected: bool):
        self.browser_connected = connected
        if not connected:
            async with self._lock:
                self.last_frame = None
                self.last_frame_jpeg = None
                self.last_frame_base64 = None
                self.last_detections = []
                self.last_annotated_frame = None
    
    async def continuous_grab(self):
        """Continuously grab frames in background with aggressive buffer flushing and timeout protection"""
        logger.info(f"Starting continuous frame grab for camera {self.config.id}")
        
        consecutive_failures = 0  # Track consecutive failures for auto-reconnect
        
        while self.running:
            try:
                if self.cap and self.cap.isOpened():
                    read_start = time.time()
                    ret, frame = await asyncio.to_thread(self._read_latest_frame)
                    read_time = time.time() - read_start
                    
                    # Log slow reads
                    if read_time > 0.5:
                        logger.warning(f"Camera {self.config.id}: Slow read ({read_time:.2f}s)")
                    
                    if ret and frame is not None:
                        consecutive_failures = 0  # Reset on success
                        self.frame_count += 1
                        
                        # Log progress every 30 frames to verify camera is working
                        if self.frame_count % 30 == 0:
                            logger.info(f"Camera {self.config.id}: Frame {self.frame_count}")
                        
                        # YOLO detection (if enabled for this camera)
                        annotated_frame = frame
                        if self.config.yolo_enabled and self.yolo_detector and self.frame_count % 2 == 0:
                            # Run detection every other frame for performance
                            try:
                                detections, annotated_frame = await asyncio.to_thread(
                                    self.yolo_detector.detect, frame
                                )
                                async with self._lock:
                                    self.last_detections = detections
                                    self.last_annotated_frame = annotated_frame
                                
                                if detections:
                                    det_str = ", ".join([f"{d.class_name}({d.confidence:.2f})" for d in detections[:3]])
                                    logger.debug(f"Camera {self.config.id} YOLO: {det_str}")
                            except Exception as e:
                                logger.error(f"YOLO detection error on camera {self.config.id}: {e}")
                        
                        # Store raw frame
                        async with self._lock:
                            self.last_frame = frame
                            
                            # Pre-encode JPEG for web display
                            # Use annotated frame if YOLO is enabled, otherwise use original
                            if self.config.streaming_enabled:
                                display_frame = annotated_frame if self.config.yolo_enabled and self.yolo_detector else frame
                                _, buffer = cv2.imencode('.jpg', display_frame, [cv2.IMWRITE_JPEG_QUALITY, 70])
                                self.last_frame_jpeg = buffer.tobytes()
                    else:
                        consecutive_failures += 1
                        logger.warning(f"Camera {self.config.id}: Read failed ({consecutive_failures} consecutive failures)")
                        
                        # Auto-reconnect after too many failures
                        if consecutive_failures >= 10:
                            logger.error(f"Camera {self.config.id}: Too many failures, attempting reconnect...")
                            self.stop()
                            await asyncio.sleep(2)
                            if await asyncio.to_thread(self.start):
                                consecutive_failures = 0
                                logger.info(f"Camera {self.config.id}: Reconnect successful")
                            else:
                                logger.error(f"Camera {self.config.id}: Reconnect failed")
                                await asyncio.sleep(5)
                    
                    # Small delay to achieve ~15 FPS
                    await asyncio.sleep(0.066)  # ~15 FPS
                else:
                    logger.warning(f"Camera {self.config.id}: Not opened, waiting...")
                    await asyncio.sleep(3)
                    if self.running:
                        await asyncio.to_thread(self._open_capture)
                    
            except Exception as e:
                logger.error(f"Camera {self.config.id} exception: {e}", exc_info=True)  # Show full stack trace
                await asyncio.sleep(1)
    
    async def get_frame(self) -> Optional[bytes]:
        """Get latest cached frame (instant, no blocking)"""
        if not self.config.streaming_enabled:
            return None
        async with self._lock:
            return self.last_frame_jpeg
    
    def get_frame_base64(self) -> Optional[str]:
        """Get frame as base64 for VLM"""
        if self.last_frame is None:
            return None
        
        # Resize for VLM (smaller = faster)
        frame_resized = cv2.resize(self.last_frame, (640, 480))
        _, buffer = cv2.imencode('.jpg', frame_resized, [cv2.IMWRITE_JPEG_QUALITY, 85])
        return base64.b64encode(buffer).decode('utf-8')
    
    def should_process(self) -> bool:
        """Check if this frame should be processed by VLM"""
        return self.frame_count % self.config.frame_interval == 0
    
    def get_detections(self) -> List[Dict]:
        """Get current YOLO detections"""
        return [
            {
                'class': d.class_name,
                'confidence': d.confidence,
                'bbox': d.bbox
            }
            for d in self.last_detections
        ]
    
    def get_yolo_summary(self) -> Optional[str]:
        """Get a simple YOLO detection summary for alerts"""
        if not self.last_detections:
            return None
        
        # Count detections by class
        class_counts = {}
        for d in self.last_detections:
            class_counts[d.class_name] = class_counts.get(d.class_name, 0) + 1
        
        # Format as "YOLO: 2x Person, 1x Car, 1x Bicycle"
        parts = [f"{count}x {cls}" if count > 1 else cls 
                 for cls, count in sorted(class_counts.items())]
        
        return "YOLO: " + ", ".join(parts)

class AlertSystem:
    """Manages alerts and logging"""
    
    def __init__(self, log_dir: str = str(Path.home() / "cctv_alerts")):
        self.log_dir = Path(log_dir)
        self.log_dir.mkdir(parents=True, exist_ok=True)
        self.alerts: List[Alert] = []
        self.max_alerts = 1000
        
        self.alert_keywords = [
            "person", "people", "suspicious", "unusual",  # Added for person detection
            "breaking", "entering", "running", "climbing", "loitering",
            "vehicle", "car", "truck", "delivery", "package",
            "fire", "smoke", "damage", "vandalism", "graffiti"
        ]
    
    def check_alert(self, response: str, camera_id: int, camera_name: str, 
                    prompt: str, image_base64: Optional[str] = None,
                    yolo_summary: Optional[str] = None) -> bool:
        """Check if VLM response triggers an alert"""
        response_lower = response.lower()
        
        triggered = any(keyword in response_lower for keyword in self.alert_keywords)
        
        if triggered:
            alert = Alert(
                timestamp=datetime.now().isoformat(),
                camera_id=camera_id,
                camera_name=camera_name,
                prompt=prompt,
                response=response,
                confidence="detected",
                image_base64=image_base64,
                yolo_summary=yolo_summary
            )
            self.add_alert(alert)
            return True
        return False
    
    def add_yolo_alert(self, camera_id: int, camera_name: str, yolo_summary: str):
        """Add a YOLO-only alert (no VLM analysis)"""
        alert = Alert(
            timestamp=datetime.now().isoformat(),
            camera_id=camera_id,
            camera_name=camera_name,
            prompt="YOLO Detection",
            response=yolo_summary,
            confidence="yolo",
            image_base64=None,
            yolo_summary=yolo_summary
        )
        self.add_alert(alert)
    
    def add_alert(self, alert: Alert):
        """Add alert to log"""
        self.alerts.insert(0, alert)
        
        if len(self.alerts) > self.max_alerts:
            self.alerts = self.alerts[:self.max_alerts]
        
        self._log_to_file(alert)
        
        logger.warning(f"🚨 ALERT on {alert.camera_name}: {alert.response[:100]}")
    
    def _log_to_file(self, alert: Alert):
        """Write alert to log file"""
        log_file = self.log_dir / f"alerts_{datetime.now().strftime('%Y%m%d')}.jsonl"
        
        alert_dict = asdict(alert)
        if alert_dict['image_base64']:
            img_file = self.log_dir / f"alert_{alert.timestamp.replace(':', '-')}_cam{alert.camera_id}.jpg"
            img_data = base64.b64decode(alert_dict['image_base64'])
            img_file.write_bytes(img_data)
            alert_dict['image_file'] = str(img_file)
            alert_dict['image_base64'] = None
        
        with open(log_file, 'a') as f:
            f.write(json.dumps(alert_dict) + '\n')
    
    def get_recent_alerts(self, limit: int = 50) -> List[Dict]:
        """Get recent alerts"""
        return [asdict(alert) for alert in self.alerts[:limit]]

    def clear(self):
        self.alerts.clear()

class MultiCameraVLMServer:
    """Main server orchestrating everything"""
    
    def __init__(self, cameras: List[CameraConfig], vlm_api_base: str, vlm_model: str, 
                 enable_yolo: bool = False, yolo_model: str = "yolo26n.pt",
                 camera_config_path: Path = CAMERA_CONFIG_PATH):
        # Initialize YOLO detector if requested
        self.yolo_detector = None
        if enable_yolo and YOLO_AVAILABLE:
            try:
                self.yolo_detector = YOLODetector(yolo_model)
                logger.info("✅ YOLO detector initialized")
            except Exception as e:
                logger.error(f"Failed to initialize YOLO: {e}")
        elif enable_yolo and not YOLO_AVAILABLE:
            logger.warning("YOLO requested but ultralytics not available. Install with: pip install ultralytics")
        
        # Initialize camera streams (pass YOLO detector to cameras that need it)
        self.cameras = {}
        for cam in cameras:
            yolo = self.yolo_detector if cam.yolo_enabled else None
            self.cameras[cam.id] = CameraStream(cam, yolo)
        
        self.vlm = VLMClient(vlm_api_base, vlm_model)
        self.alerts = AlertSystem()
        self.camera_config_path = Path(camera_config_path)
        self.running = False
        self.latest_analyses = {}
        self.latest_detections = {}  # Store latest YOLO detections per camera

    def save_camera_configs(self):
        self.camera_config_path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        os.chmod(self.camera_config_path.parent, 0o700)
        temporary_path = self.camera_config_path.with_suffix(".tmp")
        descriptor = os.open(temporary_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(descriptor, "w") as config_file:
            json.dump(
                [asdict(stream.config) for stream in self.cameras.values()],
                config_file,
                indent=2
            )
        os.replace(temporary_path, self.camera_config_path)
        os.chmod(self.camera_config_path, 0o600)

    async def start_camera(self, stream: CameraStream):
        if not stream.running:
            await asyncio.to_thread(stream.start)
        if stream.config.source_type == "browser":
            return
        if stream.grab_task is None or stream.grab_task.done():
            stream.grab_task = asyncio.create_task(stream.continuous_grab())
        
    async def start(self):
        """Start all cameras and processing"""
        logger.info("Starting Multi-Camera VLM Server")
        self.running = True
        
        # Start all enabled cameras
        for stream in self.cameras.values():
            if stream.config.enabled:
                await self.start_camera(stream)
        
        # Start processing loop
        asyncio.create_task(self.processing_loop())
        
        # NEW: Start YOLO alert loop
        asyncio.create_task(self.yolo_alert_loop())
        
    async def stop(self):
        """Stop server"""
        logger.info("Stopping server")
        self.running = False

        grab_tasks = []
        for stream in self.cameras.values():
            stream.stop()
            if stream.grab_task:
                grab_tasks.append(stream.grab_task)

        if grab_tasks:
            await asyncio.gather(*grab_tasks, return_exceptions=True)
        
        await self.vlm.close()
    
    async def process_camera_frame(self, cam_id: int, stream: CameraStream):
        """Process a single camera frame (runs concurrently)"""
        try:
            frame_b64 = stream.get_frame_base64()
            if frame_b64:
                logger.info(f"🎬 Analyzing camera {cam_id} ({stream.config.name})")
                
                # Send to VLM (non-blocking for other cameras)
                response = await self.vlm.analyze_frame(
                    frame_b64, 
                    stream.config.prompt
                )
                
                # Get YOLO summary if available
                yolo_summary = stream.get_yolo_summary()
                
                # Cache result
                self.latest_analyses[cam_id] = {
                    'timestamp': datetime.now().isoformat(),
                    'response': response,
                    'prompt': stream.config.prompt,
                    'yolo_summary': yolo_summary
                }
                
                # Check for alerts (include YOLO summary)
                self.alerts.check_alert(
                    response,
                    cam_id,
                    stream.config.name,
                    stream.config.prompt,
                    frame_b64,
                    yolo_summary
                )
                
                logger.info(f"✅ Camera {cam_id} analysis complete: {response[:50]}...")
                
        except Exception as e:
            logger.error(f"Error processing camera {cam_id}: {e}")
    
    async def yolo_alert_loop(self):
        """NEW: Post YOLO detections to alerts every minute"""
        logger.info("Starting YOLO alert loop (60 second interval)")
        
        while self.running:
            try:
                await asyncio.sleep(60)  # Wait 60 seconds
                
                # Check each camera with YOLO enabled
                for cam_id, stream in self.cameras.items():
                    if not stream.config.yolo_enabled:
                        continue
                    if not stream.config.enabled:
                        continue
                    if not stream.running:
                        continue
                    if stream.frame_count == 0:
                        continue
                    
                    # Get YOLO summary
                    yolo_summary = stream.get_yolo_summary()
                    
                    if yolo_summary:
                        logger.info(f"📊 YOLO Minute Update - Camera {cam_id}: {yolo_summary}")
                        # Add YOLO alert
                        self.alerts.add_yolo_alert(
                            camera_id=cam_id,
                            camera_name=stream.config.name,
                            yolo_summary=yolo_summary
                        )
                
            except Exception as e:
                logger.error(f"Error in YOLO alert loop: {e}")
                await asyncio.sleep(1)
    
    async def processing_loop(self):
        """Main loop: Check all cameras and spawn concurrent VLM tasks"""
        logger.info("Starting VLM processing loop (concurrent mode)")
        
        while self.running:
            try:
                tasks = []
                
                # Update YOLO detections for cameras with YOLO enabled
                for cam_id, stream in self.cameras.items():
                    if stream.config.yolo_enabled and stream.last_detections:
                        self.latest_detections[cam_id] = {
                            'timestamp': datetime.now().isoformat(),
                            'detections': stream.get_detections(),
                            'count': len(stream.last_detections)
                        }
                
                # FIX: Process ALL cameras concurrently instead of sequentially
                for cam_id, stream in self.cameras.items():
                    # Check all conditions
                    if not stream.config.enabled:
                        continue
                    if not stream.config.analysis_enabled:
                        continue
                    if not stream.running:
                        continue
                    
                    # Check if this frame should be processed
                    if stream.should_process():
                        # Create concurrent task (don't await here!)
                        task = asyncio.create_task(self.process_camera_frame(cam_id, stream))
                        tasks.append(task)
                
                # Wait for all VLM analyses to complete in parallel
                if tasks:
                    await asyncio.gather(*tasks, return_exceptions=True)
                
                # Small delay to prevent CPU thrashing
                await asyncio.sleep(0.1)
                
            except Exception as e:
                logger.error(f"Error in processing loop: {e}")
                await asyncio.sleep(1)
    
    async def get_camera_snapshot(self, cam_id: int) -> Optional[bytes]:
        """Get JPEG snapshot from camera"""
        if cam_id in self.cameras:
            return await self.cameras[cam_id].get_frame()
        return None
    
    def get_status(self) -> Dict:
        """Get server status"""
        return {
            'running': self.running,
            'yolo_enabled': self.yolo_detector is not None,
            'yolo_available': self.yolo_detector is not None,
            'cameras': {cam_id: {
                'id': stream.config.id,
                'name': stream.config.name,
                'enabled': stream.config.enabled,
                'streaming_enabled': stream.config.streaming_enabled,
                'analysis_enabled': stream.config.analysis_enabled,
                'yolo_enabled': stream.config.yolo_enabled,
                'source_type': stream.config.source_type,
                'source_label': stream.config.source_label,
                'running': stream.running,
                'connected': stream.browser_connected if stream.config.source_type == 'browser' else bool(stream.cap and stream.cap.isOpened()),
                'frame_count': stream.frame_count,
                'prompt': stream.config.prompt,
                'frame_interval': stream.config.frame_interval
            } for cam_id, stream in self.cameras.items()},
            'latest_analyses': self.latest_analyses,
            'latest_detections': self.latest_detections,
            'alert_count': len(self.alerts.alerts)
        }

# Web server
def _is_loopback_host(host: str) -> bool:
    if host.lower() == "localhost":
        return True
    try:
        return ipaddress.ip_address(host).is_loopback
    except ValueError:
        return False


def _is_lan_client(remote: str) -> bool:
    try:
        address = ipaddress.ip_address(remote)
        if isinstance(address, ipaddress.IPv6Address) and address.ipv4_mapped:
            address = address.ipv4_mapped
        return address.is_loopback or address.is_private or address.is_link_local
    except ValueError:
        return False


def _is_loopback_client(remote: str) -> bool:
    try:
        address = ipaddress.ip_address(remote)
        if isinstance(address, ipaddress.IPv6Address) and address.ipv4_mapped:
            address = address.ipv4_mapped
        return address.is_loopback
    except ValueError:
        return False


def _is_state_changing_request(request) -> bool:
    return request.method != 'GET' or request.headers.get('Upgrade', '').lower() == 'websocket'


def _has_foreign_origin(request) -> bool:
    origin = request.headers.get('Origin')
    return origin is not None and origin != f"{request.scheme}://{request.host}"


def create_server_ssl_context(host: str) -> Optional[ssl.SSLContext]:
    if _is_loopback_host(host):
        return None
    certificate = os.environ.get("CAMERA_SERVER_TLS_CERT")
    private_key = os.environ.get("CAMERA_SERVER_TLS_KEY")
    if not certificate or not private_key:
        raise RuntimeError("Non-local camera server binding requires CAMERA_SERVER_TLS_CERT and CAMERA_SERVER_TLS_KEY")
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(certificate, private_key)
    return context


async def create_app(server: MultiCameraVLMServer) -> web.Application:
    pairing_code = secrets.token_urlsafe(9)
    session_token = secrets.token_urlsafe(32)
    pair_attempts = {}
    pairing_code_used = False

    @web.middleware
    async def access_control(request, handler):
        remote = request.remote
        if remote and not _is_loopback_client(remote):
            requested_host = urlsplit(f"//{request.host}").hostname or ""
            if not _is_lan_client(remote) or not _is_lan_client(requested_host):
                return web.json_response({'error': 'Only local-network clients and hosts are allowed'}, status=403)
        if not remote or _is_loopback_client(remote):
            if _is_state_changing_request(request) and _has_foreign_origin(request):
                return web.json_response({'error': 'Request origin is not allowed'}, status=403)
            return await handler(request)
        if not request.secure:
            return web.json_response({'error': 'HTTPS is required for network access'}, status=426)
        if _is_state_changing_request(request):
            expected_origin = f"{request.scheme}://{request.host}"
            if request.headers.get('Origin') != expected_origin:
                return web.json_response({'error': 'Request origin is not allowed'}, status=403)
        if request.path == '/' or request.path == '/api/pair':
            return await handler(request)
        if not hmac.compare_digest(request.cookies.get('camera_session', ''), session_token):
            return web.json_response({'error': 'Pair this device with the server first'}, status=401)
        return await handler(request)

    app = web.Application(middlewares=[access_control])
    app['pairing_code'] = pairing_code

    async def handle_pair(request):
        nonlocal pairing_code_used
        remote = request.remote or 'unknown'
        if pairing_code_used:
            return web.json_response({'error': 'Pairing code has already been used; restart the server to pair another device'}, status=409)
        if pair_attempts.get(remote, 0) >= 5:
            return web.json_response({'error': 'Pairing attempt limit reached; restart the server to try again'}, status=429)
        try:
            data = await request.json()
        except (ValueError, web.HTTPException):
            return web.json_response({'error': 'Request body must be valid JSON'}, status=400)
        submitted_code = data.get('code', '') if isinstance(data, dict) else ''
        if not isinstance(submitted_code, str) or not hmac.compare_digest(submitted_code, pairing_code):
            pair_attempts[remote] = pair_attempts.get(remote, 0) + 1
            return web.json_response({'error': 'Pairing code is incorrect'}, status=403)
        pairing_code_used = True
        response = web.json_response({'success': True})
        response.set_cookie('camera_session', session_token, max_age=43200, httponly=True,
                            secure=True, samesite='Strict', path='/')
        return response

    async def handle_index(request):
        html_path = Path(__file__).parent / "multi_camera_vlm_ui.html"
        if html_path.exists():
            return web.FileResponse(html_path)
        return web.Response(text="UI file not found", status=404)

    async def handle_status(request):
        return web.json_response(server.get_status())

    async def handle_browser_input(request):
        try:
            camera_id = int(request.match_info['camera_id'])
        except ValueError:
            return web.Response(text='Invalid camera id', status=400)
        stream = server.cameras.get(camera_id)
        if not stream:
            return web.Response(text='Camera not found', status=404)
        if stream.config.source_type != 'browser':
            return web.Response(text='Camera does not accept browser frames', status=409)
        if stream.browser_connected:
            return web.Response(text='A browser is already connected to this camera', status=409)

        websocket = web.WebSocketResponse(max_msg_size=1_000_000, heartbeat=20)
        if not websocket.can_prepare(request).ok:
            return web.Response(text='WebSocket upgrade required', status=400)
        await websocket.prepare(request)
        await stream.set_browser_connected(True)
        last_frame_at = 0.0
        try:
            async for message in websocket:
                if server.cameras.get(camera_id) is not stream or not stream.running:
                    await websocket.close(code=1001, message=b'Camera is no longer active')
                    break
                if message.type == web.WSMsgType.BINARY:
                    if not message.data or len(message.data) > 1_000_000:
                        await websocket.close(code=1009, message=b'Frame exceeds size limit')
                        break
                    encoded_frame = np.frombuffer(message.data, dtype=np.uint8)
                    frame = cv2.imdecode(encoded_frame, cv2.IMREAD_COLOR)
                    if frame is None or frame.shape[1] > 1280 or frame.shape[0] > 720:
                        await websocket.close(code=1003, message=b'Invalid or oversized JPEG frame')
                        break
                    if time.monotonic() - last_frame_at < 0.2:
                        continue
                    await stream.receive_browser_frame(frame)
                    last_frame_at = time.monotonic()
                elif message.type in {web.WSMsgType.CLOSE, web.WSMsgType.CLOSED, web.WSMsgType.ERROR}:
                    break
                else:
                    await websocket.close(code=1003, message=b'Binary JPEG frames required')
                    break
        finally:
            await stream.set_browser_connected(False)
        return websocket

    async def handle_snapshot(request):
        camera_id = int(request.match_info['camera_id'])
        snapshot = await server.get_camera_snapshot(camera_id)
        if snapshot:
            return web.Response(body=snapshot, content_type='image/jpeg')
        return web.Response(text="Camera not available", status=404)

    async def handle_stream(request):
        camera_id = int(request.match_info['camera_id'])
        stream = server.cameras.get(camera_id)
        if not stream:
            return web.Response(text="Camera not found", status=404)

        response = web.StreamResponse(headers={
            "Content-Type": "multipart/x-mixed-replace; boundary=frame",
            "Cache-Control": "no-cache, no-store",
            "Connection": "close"
        })
        await response.prepare(request)
        try:
            while server.running and server.cameras.get(camera_id) is stream:
                if stream.config.streaming_enabled:
                    frame = await stream.get_frame()
                    if frame:
                        await response.write(
                            b"--frame\r\nContent-Type: image/jpeg\r\nContent-Length: "
                            + str(len(frame)).encode("ascii")
                            + b"\r\n\r\n" + frame + b"\r\n"
                        )
                await asyncio.sleep(0.1)
        except (ConnectionResetError, asyncio.CancelledError):
            pass
        return response

    async def handle_alerts(request):
        try:
            limit = max(0, min(1000, int(request.query.get('limit', 1000))))
        except ValueError:
            return web.json_response({'error': 'limit must be an integer'}, status=400)
        return web.json_response(server.alerts.get_recent_alerts(limit))

    async def handle_clear_alerts(request):
        server.alerts.clear()
        return web.json_response({'success': True})

    async def handle_detections(request):
        camera_id = int(request.match_info['camera_id'])
        stream = server.cameras.get(camera_id)
        if not stream:
            return web.Response(text="Camera not found", status=404)
        return web.json_response({
            'camera_id': camera_id,
            'detections': stream.get_detections(),
            'timestamp': datetime.now().isoformat()
        })

    async def handle_add_camera(request):
        try:
            data = await request.json()
        except (ValueError, web.HTTPException):
            return web.json_response({'error': 'Request body must be valid JSON'}, status=400)
        if not isinstance(data, dict):
            return web.json_response({'error': 'Request body must be an object'}, status=400)

        name = data.get('name')
        if not isinstance(name, str) or not name.strip() or len(name.strip()) > 80:
            return web.json_response({'error': 'Camera name is required and must be 80 characters or fewer'}, status=400)
        source_type = data.get('source_type', 'rtsp')
        if not isinstance(source_type, str) or source_type not in {'rtsp', 'browser'}:
            return web.json_response({'error': 'Source type must be rtsp or browser'}, status=400)
        if source_type == 'rtsp':
            try:
                rtsp_url = normalize_rtsp_url(data.get('rtsp_url'))
            except ValueError as exc:
                return web.json_response({'error': str(exc)}, status=400)
        else:
            rtsp_url = ''
        try:
            frame_interval = int(data.get('frame_interval', 60))
        except (TypeError, ValueError):
            return web.json_response({'error': 'Frame interval must be an integer'}, status=400)
        if not 1 <= frame_interval <= 3600:
            return web.json_response({'error': 'Frame interval must be between 1 and 3600'}, status=400)

        yolo_enabled = data.get('yolo_enabled', False) is True
        if yolo_enabled and not server.yolo_detector:
            return web.json_response({'error': 'YOLO model is not available'}, status=409)

        camera_id = max(server.cameras, default=0) + 1
        config = CameraConfig(
            id=camera_id,
            name=name.strip(),
            rtsp_url=rtsp_url,
            enabled=True,
            streaming_enabled=data.get('streaming_enabled', True) is True,
            analysis_enabled=data.get('analysis_enabled', False) is True,
            yolo_enabled=yolo_enabled,
            frame_interval=frame_interval,
            prompt=str(data.get('prompt', 'Describe any suspicious or unusual activity in this image.'))[:2000],
            source_type=source_type,
            source_label=str(data.get('source_label', 'Browser camera'))[:80]
        )
        stream = CameraStream(config, server.yolo_detector if yolo_enabled else None)
        server.cameras[camera_id] = stream
        try:
            server.save_camera_configs()
        except OSError:
            server.cameras.pop(camera_id, None)
            return web.json_response({'error': 'Could not save camera configuration'}, status=500)

        if config.streaming_enabled or config.analysis_enabled or config.yolo_enabled:
            if source_type == 'browser':
                await server.start_camera(stream)
            else:
                asyncio.create_task(server.start_camera(stream))
        return web.json_response({'success': True, 'camera_id': camera_id}, status=201)

    async def handle_update_camera(request):
        camera_id = int(request.match_info['camera_id'])
        stream = server.cameras.get(camera_id)
        if not stream:
            return web.Response(text="Camera not found", status=404)
        try:
            data = await request.json()
        except (ValueError, web.HTTPException):
            return web.json_response({'error': 'Request body must be valid JSON'}, status=400)
        if not isinstance(data, dict):
            return web.json_response({'error': 'Request body must be an object'}, status=400)
        if data.get('yolo_enabled') is True and not server.yolo_detector:
            return web.json_response({'error': 'YOLO model is not available'}, status=409)

        if 'name' in data:
            name = data['name']
            if not isinstance(name, str) or not name.strip() or len(name.strip()) > 80:
                return web.json_response({'error': 'Camera name is required and must be 80 characters or fewer'}, status=400)
        else:
            name = stream.config.name

        rtsp_url = stream.config.rtsp_url
        if data.get('rtsp_url'):
            try:
                rtsp_url = normalize_rtsp_url(data['rtsp_url'])
            except ValueError as exc:
                return web.json_response({'error': str(exc)}, status=400)

        frame_interval = stream.config.frame_interval
        if 'frame_interval' in data:
            try:
                frame_interval = int(data['frame_interval'])
            except (TypeError, ValueError):
                return web.json_response({'error': 'Frame interval must be an integer'}, status=400)
            if not 1 <= frame_interval <= 3600:
                return web.json_response({'error': 'Frame interval must be between 1 and 3600'}, status=400)

        url_changed = rtsp_url != stream.config.rtsp_url
        if url_changed:
            stream.stop()
            stream.config.rtsp_url = rtsp_url
            stream.frame_count = 0
            stream.last_frame = None
            stream.last_frame_jpeg = None
            stream.last_frame_base64 = None
        stream.config.name = name.strip()
        stream.config.frame_interval = frame_interval
        if 'prompt' in data:
            stream.config.prompt = str(data['prompt'])[:2000]
        if 'enabled' in data and data['enabled'] is False:
            stream.config.enabled = False
            stream.config.streaming_enabled = False
            stream.config.analysis_enabled = False
            stream.config.yolo_enabled = False
        else:
            for key in ('streaming_enabled', 'analysis_enabled', 'yolo_enabled'):
                if key in data:
                    setattr(stream.config, key, data[key] is True)
            if any((stream.config.streaming_enabled, stream.config.analysis_enabled, stream.config.yolo_enabled)):
                stream.config.enabled = True

        if stream.config.enabled and any((
            stream.config.streaming_enabled,
            stream.config.analysis_enabled,
            stream.config.yolo_enabled
        )):
            if stream.config.yolo_enabled:
                stream.yolo_detector = server.yolo_detector
            elif stream.yolo_detector:
                stream.yolo_detector = None
                stream.last_detections = []
                stream.last_annotated_frame = None
            if url_changed:
                stream.running = False
            asyncio.create_task(server.start_camera(stream))
        else:
            stream.config.enabled = False
            stream.stop()

        try:
            server.save_camera_configs()
        except OSError:
            return web.json_response({'error': 'Could not save camera configuration'}, status=500)
        return web.json_response({'success': True})

    async def handle_delete_camera(request):
        camera_id = int(request.match_info['camera_id'])
        stream = server.cameras.pop(camera_id, None)
        if not stream:
            return web.Response(text="Camera not found", status=404)
        stream.stop()
        server.latest_analyses.pop(camera_id, None)
        server.latest_detections.pop(camera_id, None)
        try:
            server.save_camera_configs()
        except OSError:
            server.cameras[camera_id] = stream
            return web.json_response({'error': 'Could not save camera configuration'}, status=500)
        return web.json_response({'success': True})

    app.router.add_get('/', handle_index)
    app.router.add_post('/api/pair', handle_pair)
    app.router.add_get('/api/status', handle_status)
    app.router.add_get('/api/camera/{camera_id}/snapshot', handle_snapshot)
    app.router.add_get('/api/camera/{camera_id}/stream', handle_stream)
    app.router.add_get('/api/camera/{camera_id}/input', handle_browser_input)
    app.router.add_get('/api/camera/{camera_id}/detections', handle_detections)
    app.router.add_get('/api/alerts', handle_alerts)
    app.router.add_delete('/api/alerts', handle_clear_alerts)
    app.router.add_post('/api/cameras', handle_add_camera)
    app.router.add_post('/api/camera/{camera_id}/update', handle_update_camera)
    app.router.add_delete('/api/camera/{camera_id}', handle_delete_camera)
    return app


async def main():
    """Main entry point"""

    server_host = os.environ.get("CAMERA_SERVER_HOST", "127.0.0.1")
    ssl_context = create_server_ssl_context(server_host)
    
    cameras = load_camera_configs()
    
    # Create server
    server = MultiCameraVLMServer(
        cameras=cameras,
        vlm_api_base="http://localhost:11434/v1",
        vlm_model="gemma3:12b",
        enable_yolo=True,  # ✨ Enable YOLO detection
        yolo_model="yolo26n.pt",
        camera_config_path=CAMERA_CONFIG_PATH
    )
    
    # Start server
    await server.start()
    
    # Create web app
    app = await create_app(server)
    
    # Run web server
    runner = web.AppRunner(app)
    await runner.setup()
    site = web.TCPSite(runner, server_host, 8095, ssl_context=ssl_context)
    await site.start()
    
    logger.info("=" * 60)
    logger.info("🎥 Multi-Camera VLM Server Running (YOLO + VLM VERSION)!")
    logger.info("=" * 60)
    logger.info("✅ FEATURES: VLM Analysis + YOLO26 Detection + Concurrent Processing")
    logger.info(f"✅ YOLO enabled: {server.yolo_detector is not None}")
    logger.info(f"✅ YOLO classes: person, bicycle, car, motorcycle, bus, truck, cat, dog, backpack, handbag, suitcase, cell phone")
    logger.info(f"✅ YOLO alerts posted every 60 seconds")
    logger.info("Open: http://localhost:8095")
    if ssl_context:
        logger.info("LAN URL: https://<Mac LAN IP>:8095")
        logger.info("LAN pairing code: %s", app['pairing_code'])
    logger.info("Press Ctrl+C to stop")
    logger.info("=" * 60)
    
    try:
        while True:
            await asyncio.sleep(3600)
    except KeyboardInterrupt:
        logger.info("Shutting down...")
        await server.stop()
        await runner.cleanup()

if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        print("\nShutdown complete")