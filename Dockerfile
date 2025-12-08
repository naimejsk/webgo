FROM node:18-alpine

# Install Tor
RUN apk add --no-cache tor

# Set working directory
WORKDIR /app

# Create package.json with onion URL configuration
RUN cat > package.json << 'EOF'
{
  "name": "tor2web-proxy",
  "version": "1.0.0",
  "description": "Tor2Web proxy service",
  "main": "server.js",
  "scripts": {
    "start": "node server.js"
  },
  "config": {
    "onionUrl": "http://3g2upl4pq6kufc4m.onion"
  },
  "dependencies": {
    "express": "^4.18.2",
    "http-proxy-middleware": "^2.0.6",
    "socks-proxy-agent": "^8.0.2"
  }
}
EOF

# Create data directory and torrc configuration
RUN mkdir -p /app/tor-data && \
    cat > /etc/tor/torrc << 'EOF'
SocksPort 0.0.0.0:9050
DataDirectory /app/tor-data
ControlPort 9051
CookieAuthentication 0
EOF

# Create Node.js server
RUN cat > server.js << 'EOF'
const express = require('express');
const { createProxyMiddleware } = require('http-proxy-middleware');
const { SocksProxyAgent } = require('socks-proxy-agent');
const packageJson = require('./package.json');

const app = express();
const PORT = process.env.PORT || 3000;
const ONION_URL = process.env.ONION_URL || packageJson.config.onionUrl;

// Wait for Tor to be ready
function waitForTor(maxAttempts = 60) {
  return new Promise((resolve, reject) => {
    let attempts = 0;
    
    const checkTor = () => {
      const net = require('net');
      const socket = net.createConnection(9050, 'localhost');
      
      socket.on('connect', () => {
        socket.destroy();
        console.log('✓ Tor SOCKS5 proxy is ready');
        resolve();
      });
      
      socket.on('error', () => {
        attempts++;
        if (attempts >= maxAttempts) {
          reject(new Error('Tor failed to start after 60 seconds'));
        } else {
          setTimeout(checkTor, 1000);
        }
      });
    };
    
    checkTor();
  });
}

// Create SOCKS proxy agent
const agent = new SocksProxyAgent('socks5h://127.0.0.1:9050');

// Proxy middleware configuration
const proxyMiddleware = createProxyMiddleware({
  target: ONION_URL,
  changeOrigin: true,
  agent: agent,
  onProxyReq: (proxyReq, req, res) => {
    // Forward original headers
    proxyReq.setHeader('X-Forwarded-For', req.ip);
    proxyReq.setHeader('X-Real-IP', req.ip);
  },
  onProxyRes: (proxyRes, req, res) => {
    // Add security headers
    proxyRes.headers['X-Powered-By'] = 'Tor2Web';
  },
  onError: (err, req, res) => {
    console.error('Proxy error:', err.message);
    res.status(502).send(`
      <html>
        <head><title>502 Bad Gateway</title></head>
        <body>
          <h1>502 Bad Gateway</h1>
          <p>Cannot reach onion service: ${ONION_URL}</p>
          <p>Error: ${err.message}</p>
        </body>
      </html>
    `);
  }
});

// Health check endpoint
app.get('/health', (req, res) => {
  res.json({ 
    status: 'ok', 
    onionUrl: ONION_URL,
    timestamp: new Date().toISOString()
  });
});

// Apply proxy to all other routes
app.use('/', proxyMiddleware);

// Start Tor and then the server
async function start() {
  console.log('Starting Tor SOCKS5 proxy...');
  
  // Start Tor in background
  const { spawn } = require('child_process');
  const tor = spawn('tor', ['-f', '/etc/tor/torrc']);
  
  tor.stdout.on('data', (data) => {
    console.log(`[Tor] ${data.toString().trim()}`);
  });
  
  tor.stderr.on('data', (data) => {
    console.error(`[Tor Error] ${data.toString().trim()}`);
  });
  
  try {
    await waitForTor();
    
    app.listen(PORT, '0.0.0.0', () => {
      console.log(`✓ Tor2Web proxy running on port ${PORT}`);
      console.log(`✓ Proxying to: ${ONION_URL}`);
      console.log(`✓ Health check: http://localhost:${PORT}/health`);
    });
  } catch (err) {
    console.error('Failed to start:', err.message);
    process.exit(1);
  }
}

start();
EOF

# Install dependencies
RUN npm install --production

# Expose port
EXPOSE 3000

# Start the application
CMD ["node", "server.js"]
