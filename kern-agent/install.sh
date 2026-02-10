#!/bin/bash
set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Configuration
SERVICE_NAME="kern-agent-service"
INSTALL_DIR="/opt/kern-agent-service"
REPO_URL="https://github.com/solactivy/kern-agent-service.git"
BRANCH="main"

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Kern Agent Service Installer${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""

# Detect OS
if [[ "$OSTYPE" == "darwin"* ]]; then
    OS="macos"
    echo -e "${YELLOW}Detected: macOS${NC}"
elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
    OS="linux"
    echo -e "${YELLOW}Detected: Linux${NC}"
else
    echo -e "${RED}Unsupported OS: $OSTYPE${NC}"
    exit 1
fi

# Check if running as root (required for system service installation)
if [ "$EUID" -ne 0 ] && [ "$OS" == "linux" ]; then 
    echo -e "${RED}Please run as root (use sudo)${NC}"
    exit 1
fi

# Check dependencies
echo -e "${YELLOW}Checking dependencies...${NC}"

# Check for Node.js
if ! command -v node &> /dev/null; then
    echo -e "${RED}Node.js is not installed. Please install Node.js 18+ first.${NC}"
    exit 1
fi

NODE_VERSION=$(node -v | cut -d'v' -f2 | cut -d'.' -f1)
if [ "$NODE_VERSION" -lt 18 ]; then
    echo -e "${RED}Node.js version 18+ required. Current version: $(node -v)${NC}"
    exit 1
fi
echo -e "${GREEN}✓ Node.js $(node -v)${NC}"

# Check for npm
if ! command -v npm &> /dev/null; then
    echo -e "${RED}npm is not installed${NC}"
    exit 1
fi
echo -e "${GREEN}✓ npm $(npm -v)${NC}"

# Check for git
if ! command -v git &> /dev/null; then
    echo -e "${RED}git is not installed${NC}"
    exit 1
fi
echo -e "${GREEN}✓ git${NC}"

# Check for OpenClaw
if ! command -v openclaw &> /dev/null; then
    echo -e "${YELLOW}⚠ OpenClaw is not installed. The service requires OpenClaw to function.${NC}"
    echo -e "${YELLOW}Install OpenClaw from: https://openclaw.ai${NC}"
    read -p "Continue anyway? (y/n) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
else
    echo -e "${GREEN}✓ OpenClaw $(openclaw --version)${NC}"
fi

# Create installation directory
echo -e "${YELLOW}Creating installation directory...${NC}"
if [ "$OS" == "macos" ]; then
    sudo mkdir -p "$INSTALL_DIR"
    sudo chown -R $(whoami):staff "$INSTALL_DIR"
else
    mkdir -p "$INSTALL_DIR"
fi

# Clone or update repository
if [ -d "$INSTALL_DIR/.git" ]; then
    echo -e "${YELLOW}Updating existing installation...${NC}"
    cd "$INSTALL_DIR"
    git fetch origin
    git reset --hard origin/$BRANCH
else
    echo -e "${YELLOW}Cloning repository...${NC}"
    git clone -b "$BRANCH" "$REPO_URL" "$INSTALL_DIR"
    cd "$INSTALL_DIR"
fi

# Install dependencies
echo -e "${YELLOW}Installing dependencies...${NC}"
npm ci --only=production

# Setup .env file
echo -e "${YELLOW}Setting up configuration...${NC}"
if [ ! -f "$INSTALL_DIR/.env" ]; then
    cat > "$INSTALL_DIR/.env" << EOF
# API Configuration
PORT=3000
API_KEY=$(openssl rand -hex 32)

# OpenClaw Gateway Configuration
OPENCLAW_GATEWAY_URL=http://127.0.0.1:18789
EOF
    echo -e "${GREEN}✓ Created .env file with generated API key${NC}"
    echo -e "${YELLOW}API Key: $(grep API_KEY "$INSTALL_DIR/.env" | cut -d'=' -f2)${NC}"
    echo -e "${YELLOW}Save this key! You'll need it to access the API.${NC}"
else
    echo -e "${GREEN}✓ Using existing .env file${NC}"
fi

# Install and start service
if [ "$OS" == "macos" ]; then
    echo -e "${YELLOW}Installing macOS service (launchd)...${NC}"
    
    # Create launchd plist
    PLIST_PATH="$HOME/Library/LaunchAgents/com.kern.agent-service.plist"
    cat > "$PLIST_PATH" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.kern.agent-service</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/local/bin/node</string>
        <string>$INSTALL_DIR/src/index.js</string>
    </array>
    <key>WorkingDirectory</key>
    <string>$INSTALL_DIR</string>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>$HOME/Library/Logs/kern-agent-service.log</string>
    <key>StandardErrorPath</key>
    <string>$HOME/Library/Logs/kern-agent-service.error.log</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
    </dict>
</dict>
</plist>
EOF
    
    # Load service
    launchctl unload "$PLIST_PATH" 2>/dev/null || true
    launchctl load "$PLIST_PATH"
    
    echo -e "${GREEN}✓ Service installed and started${NC}"
    echo -e "${YELLOW}Logs: $HOME/Library/Logs/kern-agent-service.log${NC}"
    
elif [ "$OS" == "linux" ]; then
    echo -e "${YELLOW}Installing Linux service (systemd)...${NC}"
    
    # Create systemd service file
    cat > /etc/systemd/system/kern-agent-service.service << EOF
[Unit]
Description=Kern Agent Service - REST API for OpenClaw
After=network.target

[Service]
Type=simple
User=$SUDO_USER
WorkingDirectory=$INSTALL_DIR
ExecStart=/usr/bin/node $INSTALL_DIR/src/index.js
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal
SyslogIdentifier=kern-agent-service

[Install]
WantedBy=multi-user.target
EOF
    
    # Reload systemd and start service
    systemctl daemon-reload
    systemctl enable kern-agent-service
    systemctl restart kern-agent-service
    
    echo -e "${GREEN}✓ Service installed and started${NC}"
    echo -e "${YELLOW}View logs: journalctl -u kern-agent-service -f${NC}"
fi

# Wait a moment for service to start
sleep 2

# Test the service
echo -e "${YELLOW}Testing service...${NC}"
API_KEY=$(grep API_KEY "$INSTALL_DIR/.env" | cut -d'=' -f2)
if curl -s -H "Authorization: Bearer $API_KEY" http://localhost:3000/health | grep -q "ok"; then
    echo -e "${GREEN}✓ Service is running!${NC}"
else
    echo -e "${RED}⚠ Service may not be running. Check logs.${NC}"
fi

echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Installation Complete!${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo -e "API URL: ${YELLOW}http://localhost:3000${NC}"
echo -e "API Key: ${YELLOW}$API_KEY${NC}"
echo ""
echo -e "Service Management:"
if [ "$OS" == "macos" ]; then
    echo -e "  Start:   ${YELLOW}launchctl load ~/Library/LaunchAgents/com.kern.agent-service.plist${NC}"
    echo -e "  Stop:    ${YELLOW}launchctl unload ~/Library/LaunchAgents/com.kern.agent-service.plist${NC}"
    echo -e "  Logs:    ${YELLOW}tail -f ~/Library/Logs/kern-agent-service.log${NC}"
else
    echo -e "  Start:   ${YELLOW}sudo systemctl start kern-agent-service${NC}"
    echo -e "  Stop:    ${YELLOW}sudo systemctl stop kern-agent-service${NC}"
    echo -e "  Status:  ${YELLOW}sudo systemctl status kern-agent-service${NC}"
    echo -e "  Logs:    ${YELLOW}sudo journalctl -u kern-agent-service -f${NC}"
fi
echo ""
