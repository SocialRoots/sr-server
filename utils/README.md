# SocialRoots Utilities

## Auto-start on Boot

The `socialroots.service` file enables Docker Compose services to start automatically on system boot.

### Install

```bash
# Copy to systemd
sudo cp utils/socialroots.service /etc/systemd/system/

# Enable and start
sudo systemctl daemon-reload
sudo systemctl enable socialroots
sudo systemctl start socialroots
```

### Commands

```bash
# Check status
sudo systemctl status socialroots

# Stop services
sudo systemctl stop socialroots

# Start services
sudo systemctl start socialroots

# Disable auto-start
sudo systemctl disable socialroots
```
