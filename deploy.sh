#!/bin/bash

# =============================================================================
# Production Deployment Script for Real Estate CRM
# =============================================================================
# Description: Automated deployment script for Node.js and PHP applications
# Author: Real Estate CRM Team
# Version: 1.0.0
# 
# IMPORTANT: Review and customize this script before running in production!
# File Permissions: chmod +x deploy.sh (owner execute permission)
# =============================================================================

set -euo pipefail  # Exit on error, undefined vars, pipe failures

# =============================================================================
# CONFIGURATION VARIABLES
# =============================================================================

# Application settings
APP_NAME="Real Estate CRM"
APP_DIR="/var/www/real-estate-crm"
APP_USER="www-data"
APP_GROUP="www-data"
BACKUP_DIR="/var/backups/crm"
LOG_FILE="/var/log/crm-deploy.log"

# Environment detection
ENVIRONMENT="${ENVIRONMENT:-production}"
NODE_ENV="${NODE_ENV:-production}"

# Service management
SYSTEMD_SERVICE="crm-app"
NGINX_SERVICE="nginx"
PM2_APP_NAME="crm-app"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# =============================================================================
# UTILITY FUNCTIONS
# =============================================================================

# Logging function
log() {
    local level=$1
    shift
    local message="$*"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    echo -e "${timestamp} [${level}] ${message}" | tee -a "${LOG_FILE}"
    
    case $level in
        "ERROR") echo -e "${RED}[ERROR]${NC} ${message}" ;;
        "SUCCESS") echo -e "${GREEN}[SUCCESS]${NC} ${message}" ;;
        "WARNING") echo -e "${YELLOW}[WARNING]${NC} ${message}" ;;
        "INFO") echo -e "${BLUE}[INFO]${NC} ${message}" ;;
        *) echo "[${level}] ${message}" ;;
    esac
}

# Check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Check if running as root
check_root() {
    if [[ $EUID -eq 0 ]]; then
        log "WARNING" "Running as root. Consider using a dedicated deployment user."
    fi
}

# Create backup of current deployment
create_backup() {
    log "INFO" "Creating backup of current deployment..."
    
    if [[ -d "$APP_DIR" ]]; then
        local backup_name="backup-$(date +%Y%m%d-%H%M%S)"
        local backup_path="${BACKUP_DIR}/${backup_name}"
        
        mkdir -p "$BACKUP_DIR"
        cp -r "$APP_DIR" "$backup_path"
        
        # Keep only last 5 backups
        cd "$BACKUP_DIR" && ls -t | tail -n +6 | xargs -d '\n' rm -rf --
        
        log "SUCCESS" "Backup created: $backup_path"
    else
        log "INFO" "No existing deployment to backup"
    fi
}

# =============================================================================
# DEPENDENCY INSTALLATION FUNCTIONS
# =============================================================================

# Install system dependencies
install_system_dependencies() {
    log "INFO" "Installing system dependencies..."
    
    # Update package list
    apt-get update -qq
    
    # Essential packages
    apt-get install -y \
        curl \
        wget \
        git \
        unzip \
        supervisor \
        nginx \
        mysql-client \
        redis-tools \
        logrotate \
        fail2ban \
        ufw
    
    log "SUCCESS" "System dependencies installed"
}

# Install Node.js and npm
install_nodejs() {
    if ! command_exists node; then
        log "INFO" "Installing Node.js..."
        
        # Install Node.js LTS via NodeSource repository
        curl -fsSL https://deb.nodesource.com/setup_lts.x | bash -
        apt-get install -y nodejs
        
        # Install PM2 globally for process management
        npm install -g pm2
        
        log "SUCCESS" "Node.js $(node --version) and npm $(npm --version) installed"
    else
        log "INFO" "Node.js already installed: $(node --version)"
    fi
}

# Install PHP and extensions
install_php() {
    if ! command_exists php; then
        log "INFO" "Installing PHP..."
        
        # Install PHP and common extensions
        apt-get install -y \
            php-fpm \
            php-mysql \
            php-redis \
            php-curl \
            php-gd \
            php-mbstring \
            php-xml \
            php-zip \
            php-intl \
            php-bcmath \
            composer
        
        log "SUCCESS" "PHP $(php --version | head -n1) installed"
    else
        log "INFO" "PHP already installed: $(php --version | head -n1)"
    fi
}

# =============================================================================
# APPLICATION SETUP FUNCTIONS
# =============================================================================

# Set up application directory and permissions
setup_app_directory() {
    log "INFO" "Setting up application directory..."
    
    # Create application directory
    mkdir -p "$APP_DIR"
    mkdir -p "$APP_DIR/uploads"
    mkdir -p "$APP_DIR/logs"
    mkdir -p "$APP_DIR/backups"
    mkdir -p "$APP_DIR/tmp"
    
    # Set ownership and permissions
    chown -R "$APP_USER:$APP_GROUP" "$APP_DIR"
    
    # Set directory permissions (755 for directories, 644 for files)
    find "$APP_DIR" -type d -exec chmod 755 {} \;
    find "$APP_DIR" -type f -exec chmod 644 {} \;
    
    # Special permissions for specific directories
    chmod 775 "$APP_DIR/uploads"
    chmod 775 "$APP_DIR/logs"
    chmod 775 "$APP_DIR/backups"
    chmod 777 "$APP_DIR/tmp"
    
    log "SUCCESS" "Application directory setup complete"
}

# Install Node.js dependencies
install_node_dependencies() {
    if [[ -f "$APP_DIR/package.json" ]]; then
        log "INFO" "Installing Node.js dependencies..."
        
        cd "$APP_DIR"
        
        # Use npm ci for faster, reliable, reproducible builds
        if [[ -f "package-lock.json" ]]; then
            npm ci --only=production
        else
            npm install --only=production
        fi
        
        # Build application if build script exists
        if npm run | grep -q "build"; then
            npm run build
        fi
        
        log "SUCCESS" "Node.js dependencies installed"
    else
        log "INFO" "No package.json found, skipping Node.js dependencies"
    fi
}

# Install PHP dependencies
install_php_dependencies() {
    if [[ -f "$APP_DIR/composer.json" ]]; then
        log "INFO" "Installing PHP dependencies..."
        
        cd "$APP_DIR"
        
        # Install Composer dependencies
        composer install --no-dev --optimize-autoloader
        
        log "SUCCESS" "PHP dependencies installed"
    else
        log "INFO" "No composer.json found, skipping PHP dependencies"
    fi
}

# =============================================================================
# ENVIRONMENT AND CONFIGURATION
# =============================================================================

# Load environment variables
load_environment() {
    log "INFO" "Loading environment configuration..."
    
    # Check for .env file
    if [[ ! -f "$APP_DIR/.env" ]]; then
        if [[ -f "$APP_DIR/.env.example" ]]; then
            log "WARNING" "No .env file found. Please copy .env.example to .env and configure"
            cp "$APP_DIR/.env.example" "$APP_DIR/.env"
            chmod 600 "$APP_DIR/.env"
            log "INFO" "Created .env from .env.example - PLEASE CONFIGURE IT!"
        else
            log "ERROR" "No .env or .env.example file found"
            exit 1
        fi
    fi
    
    # Source environment variables
    set -a
    source "$APP_DIR/.env"
    set +a
    
    log "SUCCESS" "Environment loaded"
}

# Run database migrations
run_migrations() {
    log "INFO" "Running database migrations..."
    
    cd "$APP_DIR"
    
    # Node.js migrations (Knex.js)
    if [[ -f "knexfile.js" ]] && command_exists npx; then
        npx knex migrate:latest
        log "SUCCESS" "Node.js migrations completed"
    fi
    
    # PHP migrations (Laravel/Artisan)
    if [[ -f "artisan" ]]; then
        php artisan migrate --force
        log "SUCCESS" "PHP migrations completed"
    fi
}

# =============================================================================
# SERVICE MANAGEMENT
# =============================================================================

# Configure and start services
configure_services() {
    log "INFO" "Configuring services..."
    
    # Configure Nginx
    if command_exists nginx; then
        configure_nginx
    fi
    
    # Configure PM2 for Node.js
    if command_exists pm2; then
        configure_pm2
    fi
    
    # Configure PHP-FPM
    if command_exists php-fpm; then
        configure_php_fpm
    fi
}

# Configure Nginx
configure_nginx() {
    log "INFO" "Configuring Nginx..."
    
    # Create Nginx configuration if it doesn't exist
    if [[ ! -f "/etc/nginx/sites-available/crm" ]]; then
        cat > "/etc/nginx/sites-available/crm" << 'EOF'
server {
    listen 80;
    server_name _;
    root /var/www/real-estate-crm/public;
    index index.php index.html index.htm;

    # Security headers
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-XSS-Protection "1; mode=block" always;

    # Gzip compression
    gzip on;
    gzip_vary on;
    gzip_types text/plain text/css application/json application/javascript text/xml application/xml application/xml+rss text/javascript;

    # Handle Node.js application
    location / {
        try_files $uri $uri/ @nodejs;
    }

    location @nodejs {
        proxy_pass http://localhost:3000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_cache_bypass $http_upgrade;
    }

    # Health check endpoint
    location /health {
        access_log off;
        proxy_pass http://localhost:3000/health;
    }

    # Static file handling
    location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg)$ {
        expires 1y;
        add_header Cache-Control "public, immutable";
    }
}
EOF
        
        # Enable site
        ln -sf "/etc/nginx/sites-available/crm" "/etc/nginx/sites-enabled/crm"
        rm -f "/etc/nginx/sites-enabled/default"
        
        # Test and reload Nginx
        nginx -t && systemctl reload nginx
    fi
    
    log "SUCCESS" "Nginx configured"
}

# Configure PM2 for Node.js
configure_pm2() {
    log "INFO" "Configuring PM2..."
    
    cd "$APP_DIR"
    
    # Stop existing PM2 processes
    pm2 stop "$PM2_APP_NAME" 2>/dev/null || true
    pm2 delete "$PM2_APP_NAME" 2>/dev/null || true
    
    # Start application with PM2
    if [[ -f "package.json" ]]; then
        pm2 start ecosystem.config.js 2>/dev/null || pm2 start server.js --name "$PM2_APP_NAME" --instances max
        pm2 save
        pm2 startup
    fi
    
    log "SUCCESS" "PM2 configured"
}

# Configure PHP-FPM
configure_php_fpm() {
    log "INFO" "Configuring PHP-FPM..."
    
    # Restart PHP-FPM service
    systemctl restart php*-fpm
    systemctl enable php*-fpm
    
    log "SUCCESS" "PHP-FPM configured"
}

# =============================================================================
# HEALTH CHECKS AND MONITORING
# =============================================================================

# Perform health checks
health_check() {
    log "INFO" "Performing health checks..."
    
    local health_status=0
    
    # Check if application responds
    if command_exists curl; then
        if curl -f -s -o /dev/null "http://localhost:3000/health" 2>/dev/null; then
            log "SUCCESS" "Application health check passed"
        else
            log "ERROR" "Application health check failed"
            health_status=1
        fi
    fi
    
    # Check services
    for service in nginx mysql redis-server; do
        if systemctl is-active --quiet "$service" 2>/dev/null; then
            log "SUCCESS" "$service is running"
        else
            log "WARNING" "$service is not running"
        fi
    done
    
    # Check PM2 processes
    if command_exists pm2; then
        pm2 list | grep -q "online" && log "SUCCESS" "PM2 processes running" || log "WARNING" "No PM2 processes running"
    fi
    
    return $health_status
}

# =============================================================================
# SECURITY HARDENING
# =============================================================================

# Apply security hardening
security_hardening() {
    log "INFO" "Applying security hardening..."
    
    # Configure firewall
    if command_exists ufw; then
        ufw --force reset
        ufw default deny incoming
        ufw default allow outgoing
        ufw allow ssh
        ufw allow http
        ufw allow https
        ufw --force enable
        log "SUCCESS" "Firewall configured"
    fi
    
    # Configure fail2ban
    if command_exists fail2ban-client; then
        systemctl enable fail2ban
        systemctl start fail2ban
        log "SUCCESS" "Fail2ban configured"
    fi
    
    # Set secure file permissions
    find "$APP_DIR" -name "*.env*" -exec chmod 600 {} \;
    find "$APP_DIR" -name "*.key" -exec chmod 600 {} \;
    
    log "SUCCESS" "Security hardening applied"
}

# =============================================================================
# MAIN DEPLOYMENT FUNCTION
# =============================================================================

main() {
    log "INFO" "Starting deployment of $APP_NAME"
    log "INFO" "Environment: $ENVIRONMENT"
    log "INFO" "Timestamp: $(date)"
    
    # Preliminary checks
    check_root
    
    # Create backup before deployment
    create_backup
    
    # Install dependencies
    install_system_dependencies
    install_nodejs
    install_php
    
    # Setup application
    setup_app_directory
    load_environment
    install_node_dependencies
    install_php_dependencies
    
    # Database setup
    run_migrations
    
    # Configure and start services
    configure_services
    
    # Security hardening
    security_hardening
    
    # Final health check
    if health_check; then
        log "SUCCESS" "Deployment completed successfully!"
        log "INFO" "Application should be available at: http://localhost"
    else
        log "ERROR" "Deployment completed with warnings. Please check the logs."
        exit 1
    fi
}

# =============================================================================
# SCRIPT EXECUTION
# =============================================================================

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --environment|-e)
            ENVIRONMENT="$2"
            shift 2
            ;;
        --app-dir|-d)
            APP_DIR="$2"
            shift 2
            ;;
        --help|-h)
            echo "Usage: $0 [OPTIONS]"
            echo "Options:"
            echo "  -e, --environment    Set deployment environment (default: production)"
            echo "  -d, --app-dir        Set application directory (default: /var/www/real-estate-crm)"
            echo "  -h, --help           Show this help message"
            exit 0
            ;;
        *)
            log "ERROR" "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Create log directory and file
mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE"

# Run main deployment function
main "$@"

# =============================================================================
# DEPLOYMENT NOTES:
# =============================================================================
# 1. Run with: sudo ./deploy.sh
# 2. Ensure proper file permissions: chmod +x deploy.sh
# 3. Review configuration variables at the top of this script
# 4. Test in staging environment before production deployment
# 5. Monitor logs: tail -f /var/log/crm-deploy.log
# 6. For rollback: restore from backup in /var/backups/crm
# 7. Health checks available at: http://localhost:3000/health
# 8. PM2 process management: pm2 list, pm2 restart, pm2 logs
# 9. Service management: systemctl status nginx|mysql|redis-server
# 10. Regular maintenance: update dependencies, rotate logs, clean backups
# =============================================================================