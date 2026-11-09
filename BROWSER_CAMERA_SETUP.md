# Browser Camera Setup

Browser cameras use the camera on the device currently showing the page. The browser sends silent JPEG frames to the Python server at up to 2 FPS. The iPhone page must stay in the foreground; iOS may stop camera capture when Safari is backgrounded or the phone is locked.

## Local Mac use

Open `http://localhost:8095`. Localhost is a secure browser context, so the browser can request camera permission. Choose **This device camera**, select the Mac camera, and add it.

## iPhone on the same LAN

The iPhone must trust a local certificate before Safari will grant camera access to the Mac-hosted page. Keep the mkcert root private; transfer only `rootCA.pem` to the phone.

1. Install mkcert and create a local CA:

   ```sh
   brew install mkcert
   mkcert -install
   ```

2. Find the Mac's LAN IP and issue a certificate for it. Replace the example address with the Mac's current LAN IP:

   ```sh
    CERT_DIR="$HOME/Library/Application Support/MultiCameraVLM/certs"
    mkdir -p "$CERT_DIR"
    mkcert -cert-file "$CERT_DIR/camera-server.pem" \
       -key-file "$CERT_DIR/camera-server-key.pem" \
     192.168.1.20 localhost 127.0.0.1 ::1
   mkcert -CAROOT
   ```

3. AirDrop the `rootCA.pem` from the directory printed by `mkcert -CAROOT` to the iPhone. Install its configuration profile under **Settings > General > VPN & Device Management**, then enable full trust under **Settings > General > About > Certificate Trust Settings**.

4. Start the server with TLS enabled:

   ```sh
   CAMERA_SERVER_HOST=0.0.0.0 \
   CAMERA_SERVER_TLS_CERT="$HOME/Library/Application Support/MultiCameraVLM/certs/camera-server.pem" \
   CAMERA_SERVER_TLS_KEY="$HOME/Library/Application Support/MultiCameraVLM/certs/camera-server-key.pem" \
   ./.venv/bin/python multi_camera_vlm_server_yolo2.py
   ```

5. On the iPhone, open `https://192.168.1.20:8095` using the same LAN IP as the certificate. Enter the one-time pairing code printed by the server, choose **This device camera**, and add it. The paired session expires after 12 hours and must be paired again after a server restart.

The server rejects non-private network clients and requires TLS plus pairing for LAN API access. Keep the Mac firewall enabled and do not forward port 8095 from the internet. If the Mac's LAN IP changes, issue a new certificate and trust it on the phone.