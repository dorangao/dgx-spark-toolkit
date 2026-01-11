/* ==========================================================================
   DGX Spark Toolkit - Cluster Control UI
   Unified JavaScript Module
   ========================================================================== */

// ============================================================================
// Toast Notification System
// ============================================================================
const Toast = {
  container: null,

  init() {
    this.container = document.getElementById('toast-container');
    if (!this.container) {
      this.container = document.createElement('div');
      this.container.id = 'toast-container';
      this.container.className = 'toast-container';
      document.body.appendChild(this.container);
    }
  },

  show(message, type = 'info', duration = 4000) {
    if (!this.container) this.init();
    
    const toast = document.createElement('div');
    toast.className = `toast ${type}`;
    toast.textContent = message;
    this.container.appendChild(toast);
    
    setTimeout(() => {
      toast.style.opacity = '0';
      toast.style.transform = 'translateX(100%)';
      setTimeout(() => toast.remove(), 300);
    }, duration);
  },

  success: (msg) => Toast.show(msg, 'success'),
  error: (msg) => Toast.show(msg, 'error'),
  info: (msg) => Toast.show(msg, 'info'),
  warning: (msg) => Toast.show(msg, 'warning'),
};

// ============================================================================
// Modal System
// ============================================================================
const Modal = {
  show(id) {
    const modal = document.getElementById(id);
    if (modal) modal.classList.add('show');
  },

  hide(id) {
    const modal = document.getElementById(id);
    if (modal) modal.classList.remove('show');
  },

  confirm(message, onConfirm) {
    const modal = document.getElementById('confirm-modal');
    const msgEl = document.getElementById('confirm-message');
    const confirmBtn = document.getElementById('confirm-btn');
    
    if (modal && msgEl && confirmBtn) {
      msgEl.textContent = message;
      confirmBtn.onclick = () => {
        Modal.hide('confirm-modal');
        if (onConfirm) onConfirm();
      };
      modal.classList.add('show');
    }
  },
};

// ============================================================================
// Tab Navigation
// ============================================================================
const Tabs = {
  buttons: null,
  contents: null,
  callbacks: {},

  init() {
    this.buttons = document.querySelectorAll('[data-tab-target]');
    this.contents = document.querySelectorAll('.tab-content');
    
    this.buttons.forEach(btn => {
      btn.addEventListener('click', () => this.activate(btn.dataset.tabTarget));
    });
  },

  activate(target) {
    this.buttons.forEach(btn => {
      btn.classList.toggle('active', btn.dataset.tabTarget === target);
    });
    this.contents.forEach(panel => {
      panel.classList.toggle('active', panel.id === `tab-${target}`);
    });
    // Fire callback if registered
    if (this.callbacks[target]) {
      this.callbacks[target]();
    }
  },

  onActivate(tabName, callback) {
    this.callbacks[tabName] = callback;
  },
};

// ============================================================================
// API Client
// ============================================================================
const API = {
  async get(url) {
    const response = await fetch(url);
    return response.json();
  },

  async post(url, data = {}) {
    const response = await fetch(url, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(data),
    });
    return response.json();
  },

  async stream(url, method = 'POST', data = {}, onData) {
    const response = await fetch(url, {
      method,
      headers: method === 'POST' ? { 'Content-Type': 'application/json' } : {},
      body: method === 'POST' ? JSON.stringify(data) : undefined,
    });
    
    if (!response.ok) {
      throw new Error(await response.text());
    }
    
    const reader = response.body.getReader();
    const decoder = new TextDecoder();
    
    while (true) {
      const { value, done } = await reader.read();
      if (done) break;
      onData(decoder.decode(value));
    }
  },
};

// ============================================================================
// SSE Stream Manager
// ============================================================================
class SSEStream {
  constructor(url, onMessage, options = {}) {
    this.url = url;
    this.onMessage = onMessage;
    this.onError = options.onError || (() => {});
    this.onStatus = options.onStatus || (() => {});
    this.source = null;
    
    // Reconnection settings
    this.reconnectAttempts = 0;
    this.maxReconnectAttempts = options.maxReconnectAttempts || 10;
    this.baseReconnectDelay = options.baseReconnectDelay || 1000;
    this.maxReconnectDelay = options.maxReconnectDelay || 30000;
    this.reconnectTimer = null;
    this.isStopped = true;
    this.isPageVisible = !document.hidden;
    
    // Handle page visibility changes
    this._handleVisibility = () => {
      this.isPageVisible = !document.hidden;
      if (this.isPageVisible && !this.isStopped && !this.source) {
        // Page became visible, try to reconnect
        this._scheduleReconnect(0);
      } else if (!this.isPageVisible && this.source) {
        // Page hidden - let browser handle, but don't spam errors
      }
    };
    document.addEventListener('visibilitychange', this._handleVisibility);
  }

  start() {
    this.isStopped = false;
    this.reconnectAttempts = 0;
    this._connect();
  }

  _connect() {
    if (this.isStopped) return;
    if (this.source) this._closeSource();
    
    // Don't connect if page is hidden
    if (!this.isPageVisible) {
      this.onStatus('paused', '#6b7280');
      return;
    }
    
    this.onStatus('connecting', '#f59e0b');
    
    try {
      this.source = new EventSource(this.url);
      
      this.source.onmessage = (event) => {
        try {
          const data = JSON.parse(event.data);
          this.onMessage(data);
          this.onStatus('connected', '#22c55e');
          this.reconnectAttempts = 0; // Reset on successful message
        } catch (err) {
          console.warn('SSE parse error:', err);
        }
      };
      
      this.source.onerror = (e) => {
        // Don't log errors for expected disconnections
        if (this.isStopped || !this.isPageVisible) return;
        
        this._closeSource();
        
        if (this.reconnectAttempts < this.maxReconnectAttempts) {
          this._scheduleReconnect();
        } else {
          this.onStatus('failed', '#ef4444');
          this.onError();
        }
      };
      
      this.source.onopen = () => {
        this.onStatus('connected', '#22c55e');
        this.reconnectAttempts = 0;
      };
    } catch (err) {
      console.warn('SSE connection error:', err);
      this._scheduleReconnect();
    }
  }
  
  _closeSource() {
    if (this.source) {
      this.source.onmessage = null;
      this.source.onerror = null;
      this.source.onopen = null;
      this.source.close();
      this.source = null;
    }
  }
  
  _scheduleReconnect(overrideDelay) {
    if (this.isStopped) return;
    if (this.reconnectTimer) clearTimeout(this.reconnectTimer);
    
    // Exponential backoff with jitter
    const delay = overrideDelay !== undefined ? overrideDelay : 
      Math.min(this.baseReconnectDelay * Math.pow(2, this.reconnectAttempts) + Math.random() * 1000, 
               this.maxReconnectDelay);
    
    this.reconnectAttempts++;
    this.onStatus(`reconnecting (${this.reconnectAttempts}/${this.maxReconnectAttempts})`, '#f59e0b');
    
    this.reconnectTimer = setTimeout(() => {
      this.reconnectTimer = null;
      this._connect();
    }, delay);
  }

  stop() {
    this.isStopped = true;
    if (this.reconnectTimer) {
      clearTimeout(this.reconnectTimer);
      this.reconnectTimer = null;
    }
    this._closeSource();
    this.onStatus('', '');
  }
  
  destroy() {
    this.stop();
    document.removeEventListener('visibilitychange', this._handleVisibility);
  }
}

// ============================================================================
// Chart Manager
// ============================================================================
const ChartManager = {
  charts: {},

  create(id, type, labels, datasets, options = {}) {
    const canvas = document.getElementById(id);
    if (!canvas || typeof Chart === 'undefined') return null;
    
    // Destroy existing chart
    if (this.charts[id]) {
      this.charts[id].destroy();
    }
    
    const defaultOptions = {
      responsive: true,
      maintainAspectRatio: false,
      animation: false,
      plugins: { legend: { position: 'bottom' } },
      scales: {
        y: { suggestedMin: 0, suggestedMax: 100, beginAtZero: true, ticks: { stepSize: 20 } },
        x: { ticks: { maxTicksLimit: 6 } },
      },
    };
    
    this.charts[id] = new Chart(canvas.getContext('2d'), {
      type,
      data: { labels, datasets },
      options: { ...defaultOptions, ...options },
    });
    
    return this.charts[id];
  },

  destroy(id) {
    if (this.charts[id]) {
      this.charts[id].destroy();
      delete this.charts[id];
    }
  },
};

// ============================================================================
// Deployment Manager (unified for LLM and ImageGen)
// ============================================================================
class DeploymentManager {
  constructor(config) {
    this.namespace = config.namespace;
    this.apiPrefix = config.apiPrefix;
    this.elements = config.elements || {};
    this.models = {};
    this.currentModel = null;
    this.status = {};
    this.inProgress = false;
  }

  async loadModels() {
    try {
      const data = await API.get(`${this.apiPrefix}/models`);
      this.models = data.models || {};
      this.currentModel = data.current_model;
      this.updateModelSelector();
      return data;
    } catch (err) {
      console.error('Failed to load models:', err);
      return { models: {} };
    }
  }

  async loadStatus() {
    try {
      this.status = await API.get(`${this.apiPrefix}/status`);
      this.updateStatusUI();
      return this.status;
    } catch (err) {
      console.error('Failed to load status:', err);
      return {};
    }
  }

  async deploy(mode, model) {
    if (this.inProgress) {
      Toast.error('Another operation is in progress...');
      return false;
    }

    this.inProgress = true;
    this.setButtonsDisabled(true);
    Toast.info(`Deploying ${model}...`);

    try {
      const data = await API.post(`${this.apiPrefix}/deploy/${mode}`, { model });
      
      if (data.success) {
        Toast.success(data.message || 'Deployment initiated!');
        this.pollStatus();
        return true;
      } else {
        Toast.error(`Deployment failed: ${data.message || data.error}`);
        return false;
      }
    } catch (err) {
      Toast.error(`Error: ${err}`);
      return false;
    } finally {
      this.inProgress = false;
      this.setButtonsDisabled(false);
    }
  }

  async delete() {
    if (this.inProgress) {
      Toast.error('Another operation is in progress...');
      return false;
    }

    this.inProgress = true;
    this.setButtonsDisabled(true);
    Toast.info('Deleting deployment...');

    try {
      const data = await API.post(`${this.apiPrefix}/delete`);
      
      if (data.success) {
        Toast.success(data.message || 'Deployment deleted!');
        this.loadStatus();
        return true;
      } else {
        Toast.error(`Delete failed: ${data.message || data.error}`);
        return false;
      }
    } catch (err) {
      Toast.error(`Error: ${err}`);
      return false;
    } finally {
      this.inProgress = false;
      this.setButtonsDisabled(false);
    }
  }

  async scale(replicas) {
    try {
      const data = await API.post(`${this.apiPrefix}/scale`, { replicas });
      Toast.show(data.message || data.error, data.success ? 'success' : 'error');
      this.loadStatus();
      return data.success;
    } catch (err) {
      Toast.error(`Scale error: ${err}`);
      return false;
    }
  }

  async getLogs(lines = 100) {
    try {
      return await API.get(`${this.apiPrefix}/logs?lines=${lines}`);
    } catch (err) {
      return { success: false, error: String(err) };
    }
  }

  pollStatus(times = [5000, 15000, 30000, 60000]) {
    times.forEach(delay => {
      setTimeout(() => this.loadStatus(), delay);
    });
  }

  setButtonsDisabled(disabled) {
    document.querySelectorAll('.ops-btn').forEach(btn => btn.disabled = disabled);
  }

  updateModelSelector() {
    const selector = this.elements.modelSelector && document.getElementById(this.elements.modelSelector);
    if (!selector || !Object.keys(this.models).length) return;
    
    selector.innerHTML = '';
    for (const [key, model] of Object.entries(this.models)) {
      const opt = document.createElement('option');
      opt.value = key;
      const sizeInfo = model.size_gb ? `${model.size_gb}GB` : '';
      const gpuInfo = model.min_gpus ? `${model.min_gpus} GPU` : '';
      opt.textContent = `${model.display_name || key} (${[sizeInfo, gpuInfo].filter(Boolean).join(', ')})`;
      if (key === this.currentModel) opt.selected = true;
      selector.appendChild(opt);
    }
  }

  updateStatusUI() {
    // Override in subclass
  }
}

// ============================================================================
// LLM Manager
// ============================================================================
class LLMManager extends DeploymentManager {
  constructor() {
    super({
      namespace: 'llm-inference',
      apiPrefix: '/nemotron',
      elements: {
        modelSelector: 'llm-model-select',
        statusBadge: 'llm-mode-badge',
        currentModel: 'llm-current-model',
        vllmDot: 'llm-vllm-dot',
        litellmDot: 'llm-litellm-dot',
        logs: 'llm-logs',
      },
    });
    this.chatHistory = [];
  }

  updateStatusUI() {
    const { status } = this;
    
    // Status badge
    const badge = document.getElementById(this.elements.statusBadge);
    if (badge) {
      badge.className = `mode-badge ${(status.mode || 'not-deployed').replace('_', '-')}`;
      const modeText = {
        'distributed': 'Distributed',
        'distributed_stopped': 'Stopped',
        'single': 'Single Node',
        'single_stopped': 'Stopped',
        'not_deployed': 'Not Deployed',
      };
      badge.textContent = modeText[status.mode] || status.mode || 'Unknown';
    }
    
    // Current model
    const modelEl = document.getElementById(this.elements.currentModel);
    if (modelEl) {
      this.currentModel = status.current_model_display || status.current_model;
      modelEl.textContent = this.currentModel || 'None';
    }
    
    // Health indicators
    const vllmDot = document.getElementById(this.elements.vllmDot);
    const litellmDot = document.getElementById(this.elements.litellmDot);
    if (vllmDot && status.vllm_health) {
      vllmDot.className = `health-dot ${status.vllm_health.healthy ? 'online' : 'offline'}`;
    }
    if (litellmDot && status.litellm_health) {
      litellmDot.className = `health-dot ${status.litellm_health.healthy ? 'online' : 'offline'}`;
    }
    
    // Update buttons
    const isDeployed = status.mode !== 'not_deployed';
    const isRunning = status.mode === 'distributed' || status.mode === 'single';
    const isStopped = (status.mode || '').includes('stopped');
    
    const startBtn = document.getElementById('llm-start-btn');
    const stopBtn = document.getElementById('llm-stop-btn');
    const deleteBtn = document.getElementById('llm-delete-btn');
    
    if (startBtn) startBtn.disabled = !isStopped;
    if (stopBtn) stopBtn.disabled = !isRunning;
    if (deleteBtn) deleteBtn.disabled = !isDeployed;
  }

  async start() {
    Toast.info('Starting model...');
    try {
      const data = await API.post('/nemotron/start');
      if (data.success) {
        Toast.success('Model starting! May take a few minutes.');
        this.pollStatus([5000, 30000]);
      } else {
        Toast.error(`Start failed: ${data.message}`);
      }
    } catch (err) {
      Toast.error(`Error: ${err}`);
    }
  }

  async stop() {
    Toast.info('Stopping model...');
    try {
      const data = await API.post('/nemotron/stop');
      if (data.success) {
        Toast.success('Model stopped.');
        this.loadStatus();
      } else {
        Toast.error(`Stop failed: ${data.message}`);
      }
    } catch (err) {
      Toast.error(`Error: ${err}`);
    }
  }

  async restart() {
    Toast.info('Restarting vLLM...');
    try {
      const data = await API.post('/nemotron/restart');
      if (data.success) {
        Toast.success('vLLM restart initiated.');
        this.pollStatus([10000, 60000]);
      } else {
        Toast.error(`Restart failed: ${data.message}`);
      }
    } catch (err) {
      Toast.error(`Error: ${err}`);
    }
  }

  async refreshLogs() {
    const logsEl = document.getElementById(this.elements.logs);
    if (!logsEl) return;
    
    const data = await this.getLogs(100);
    logsEl.textContent = data.success ? (data.logs || 'No logs available.') : `Error: ${data.error}`;
    logsEl.scrollTop = logsEl.scrollHeight;
  }

  // Chat functionality
  clearChat() {
    this.chatHistory = [];
    const messagesEl = document.getElementById('llm-chat-messages');
    if (messagesEl) {
      messagesEl.innerHTML = `
        <div class="chat-message system">Chat cleared. Start a new conversation!</div>
      `;
    }
  }

  addMessage(role, content) {
    const messagesEl = document.getElementById('llm-chat-messages');
    if (!messagesEl) return null;
    
    // Remove placeholder
    const placeholder = messagesEl.querySelector('.chat-message.system');
    if (placeholder && placeholder.textContent.includes('Deploy a model')) {
      placeholder.remove();
    }
    
    const msgDiv = document.createElement('div');
    msgDiv.className = `chat-message ${role}`;
    
    const label = document.createElement('div');
    label.className = 'chat-message-label';
    label.textContent = role === 'user' ? 'You' : (this.currentModel || 'Assistant');
    
    const text = document.createElement('div');
    text.className = 'chat-message-text';
    text.textContent = content;
    
    msgDiv.appendChild(label);
    msgDiv.appendChild(text);
    messagesEl.appendChild(msgDiv);
    messagesEl.scrollTop = messagesEl.scrollHeight;
    
    return text;
  }

  async sendMessage() {
    const inputEl = document.getElementById('llm-chat-input');
    const message = inputEl.value.trim();
    if (!message) return;
    
    this.chatHistory.push({ role: 'user', content: message });
    this.addMessage('user', message);
    inputEl.value = '';
    
    const useLiteLLM = document.getElementById('llm-use-litellm')?.checked ?? true;
    const maxTokens = parseInt(document.getElementById('llm-max-tokens')?.value) || 1024;
    const temperature = parseFloat(document.getElementById('llm-temperature')?.value) || 0.7;
    const useStream = document.getElementById('llm-stream')?.checked ?? true;
    
    const sendBtn = document.getElementById('llm-send-btn');
    if (sendBtn) {
      sendBtn.disabled = true;
      sendBtn.textContent = '...';
    }
    
    try {
      if (useStream) {
        const textEl = this.addMessage('assistant', '');
        let fullContent = '';
        
        await API.stream('/llm/chat/stream', 'POST', {
          messages: this.chatHistory,
          max_tokens: maxTokens,
          temperature,
          use_litellm: useLiteLLM,
        }, (chunk) => {
          const lines = chunk.split('\n');
          for (const line of lines) {
            if (line.startsWith('data: ')) {
              const data = line.slice(6);
              if (data === '[DONE]') continue;
              try {
                const parsed = JSON.parse(data);
                if (parsed.error) {
                  textEl.textContent = `Error: ${parsed.error}`;
                  break;
                }
                const delta = parsed.choices?.[0]?.delta?.content || '';
                if (delta) {
                  fullContent += delta;
                  textEl.textContent = fullContent;
                }
              } catch {}
            }
          }
        });
        
        if (fullContent) {
          this.chatHistory.push({ role: 'assistant', content: fullContent });
        }
      } else {
        const data = await API.post('/llm/chat', {
          messages: this.chatHistory,
          max_tokens: maxTokens,
          temperature,
          use_litellm: useLiteLLM,
        });
        
        if (data.success) {
          this.addMessage('assistant', data.content);
          this.chatHistory.push({ role: 'assistant', content: data.content });
        } else {
          this.addMessage('assistant', `Error: ${data.error}`);
        }
      }
    } catch (err) {
      this.addMessage('assistant', `Error: ${err}`);
    } finally {
      if (sendBtn) {
        sendBtn.disabled = false;
        sendBtn.textContent = 'Send ➤';
      }
    }
  }
}

// ============================================================================
// Image Generation Manager
// ============================================================================
class ImageGenManager extends DeploymentManager {
  constructor() {
    super({
      namespace: 'image-gen',
      apiPrefix: '/imagegen',
      elements: {
        modelSelector: 'imagegen-model-select',
        statusBadge: 'imagegen-status-badge',
        currentModel: 'imagegen-current-model',
        healthDot: 'imagegen-health-dot',
        podsStatus: 'imagegen-pods-status',
        endpoint: 'imagegen-endpoint',
        logs: 'imagegen-logs',
      },
    });
    this.currentImage = null;
  }

  updateStatusUI() {
    const { status } = this;
    
    const badge = document.getElementById(this.elements.statusBadge);
    const healthDot = document.getElementById(this.elements.healthDot);
    const modelDiv = document.getElementById(this.elements.currentModel);
    const podsDiv = document.getElementById(this.elements.podsStatus);
    const endpointDiv = document.getElementById(this.elements.endpoint);
    const gradioLink = document.getElementById('imagegen-gradio-link');
    
    if (status.deployed) {
      if (badge) {
        badge.textContent = status.ready ? 'Running' : 'Starting...';
        badge.className = `mode-badge ${status.ready ? 'running' : 'pending'}`;
      }
      if (modelDiv) modelDiv.textContent = status.model || 'Unknown';
      if (podsDiv) podsDiv.textContent = `${status.ready_replicas || 0}/${status.replicas || 0} Ready`;
      
      if (status.endpoint) {
        if (endpointDiv) endpointDiv.innerHTML = `<code>${status.endpoint}</code>`;
        if (gradioLink) {
          gradioLink.href = status.endpoint;
          gradioLink.style.display = 'inline';
        }
      }
      
      // Pods detail
      if (podsDiv && status.pods && status.pods.length > 0) {
        const podInfo = status.pods.map(p => `${p.name.slice(-12)}: ${p.status}`).join('\n');
        podsDiv.innerHTML = `<pre style="margin:0;font-size:0.75rem;">${podInfo}</pre>`;
      }
    } else {
      if (badge) {
        badge.textContent = 'Not Deployed';
        badge.className = 'mode-badge not-deployed';
      }
      if (modelDiv) modelDiv.textContent = 'None';
      if (podsDiv) podsDiv.textContent = '-';
      if (endpointDiv) endpointDiv.innerHTML = '<code>Not available</code>';
      if (gradioLink) gradioLink.style.display = 'none';
    }
    
    if (healthDot) {
      healthDot.className = `health-dot ${status.ready ? 'online' : 'offline'}`;
    }
  }

  async generate() {
    const prompt = document.getElementById('imagegen-prompt')?.value?.trim();
    if (!prompt) {
      Toast.warning('Please enter a prompt');
      return;
    }
    
    const elements = {
      generateBtn: document.getElementById('imagegen-generate-btn'),
      placeholder: document.getElementById('imagegen-placeholder'),
      resultImg: document.getElementById('imagegen-result'),
      loading: document.getElementById('imagegen-loading'),
      loadingText: document.getElementById('imagegen-loading-text'),
      downloadBtn: document.getElementById('imagegen-download-btn'),
    };
    
    // Show loading state
    if (elements.generateBtn) {
      elements.generateBtn.disabled = true;
      elements.generateBtn.textContent = '⏳ Generating...';
    }
    if (elements.placeholder) elements.placeholder.style.display = 'none';
    if (elements.resultImg) elements.resultImg.style.display = 'none';
    if (elements.loading) elements.loading.style.display = 'block';
    if (elements.downloadBtn) elements.downloadBtn.disabled = true;
    
    const width = parseInt(document.getElementById('imagegen-width')?.value) || 1024;
    const height = parseInt(document.getElementById('imagegen-height')?.value) || 1024;
    const steps = parseInt(document.getElementById('imagegen-steps')?.value) || 25;
    
    // Estimate time
    let estimatedTime = 10;
    if (width >= 1024 && height >= 1024) estimatedTime = 70;
    if (width >= 1280 || height >= 1280) estimatedTime = 130;
    if (width >= 1536 || height >= 1536) estimatedTime = 190;
    estimatedTime = Math.round(estimatedTime * (steps / 25));
    
    if (elements.loadingText) {
      elements.loadingText.textContent = `Generating ${width}×${height} image (~${estimatedTime}s)...`;
    }
    
    try {
      const data = await API.post('/imagegen/generate', {
        prompt,
        negative_prompt: document.getElementById('imagegen-negative-prompt')?.value || '',
        width,
        height,
        steps,
        guidance_scale: parseFloat(document.getElementById('imagegen-guidance')?.value) || 7.5,
        seed: parseInt(document.getElementById('imagegen-seed')?.value) || -1,
      });
      
      if (data.success && data.image_base64) {
        this.currentImage = data.image_base64;
        if (elements.resultImg) {
          elements.resultImg.src = `data:image/png;base64,${data.image_base64}`;
          elements.resultImg.style.display = 'block';
        }
        if (elements.loading) elements.loading.style.display = 'none';
        if (elements.downloadBtn) elements.downloadBtn.disabled = false;
        Toast.success('Image generated successfully!');
      } else {
        throw new Error(data.error || 'Generation failed');
      }
    } catch (err) {
      if (elements.loading) elements.loading.style.display = 'none';
      if (elements.placeholder) {
        elements.placeholder.style.display = 'block';
        elements.placeholder.innerHTML = `
          <div style="color:#ef4444;font-size:1.5rem;">❌</div>
          <p style="color:#ef4444;margin-top:0.5rem;">Generation failed</p>
          <p style="font-size:0.8rem;margin-top:0.5rem;">${err.message || err}</p>
        `;
      }
      Toast.error(`Generation failed: ${err}`);
    } finally {
      if (elements.generateBtn) {
        elements.generateBtn.disabled = false;
        elements.generateBtn.textContent = '🎨 Generate';
      }
    }
  }

  download() {
    if (!this.currentImage) return;
    
    const link = document.createElement('a');
    link.href = `data:image/png;base64,${this.currentImage}`;
    link.download = `generated-${Date.now()}.png`;
    document.body.appendChild(link);
    link.click();
    document.body.removeChild(link);
    Toast.success('Image downloaded!');
  }

  clear() {
    document.getElementById('imagegen-prompt').value = '';
    document.getElementById('imagegen-placeholder').style.display = 'block';
    document.getElementById('imagegen-result').style.display = 'none';
    document.getElementById('imagegen-loading').style.display = 'none';
    document.getElementById('imagegen-download-btn').disabled = true;
    this.currentImage = null;
  }

  async refreshLogs() {
    const logsEl = document.getElementById(this.elements.logs);
    if (!logsEl) return;
    
    const data = await this.getLogs(100);
    logsEl.textContent = data.success ? (data.logs || 'No logs available') : `Error: ${data.error}`;
  }
}

// ============================================================================
// Host Metrics Manager
// ============================================================================
class HostMetricsManager {
  constructor(containerId, options = {}) {
    this.container = document.getElementById(containerId);
    this.history = {};
    this.netHistory = {};
    this.charts = {};
    this.netCharts = {};
    this.stream = null;
    this.maxPoints = options.maxPoints || 120;
  }

  start(streamUrl = '/host-metrics-stream') {
    this.stream = new SSEStream(streamUrl, 
      (data) => this.handleData(Array.isArray(data) ? data : []),
      {
        onStatus: (status, color) => this.updateSSEStatus(status, color),
      }
    );
    this.stream.start();
  }

  stop() {
    if (this.stream) {
      this.stream.stop();
      this.stream = null;
    }
    if (this.container) {
      this.container.innerHTML = '<p class="muted">Performance tracking disabled.</p>';
    }
  }

  updateSSEStatus(status, color) {
    const el = document.getElementById('sse-status');
    if (el) {
      el.textContent = status ? `● ${status.charAt(0).toUpperCase() + status.slice(1)}` : '';
      el.style.color = color || 'inherit';
    }
  }

  handleData(entries) {
    if (!this.container) return;
    
    entries.forEach(entry => this.updateHistory(entry));
    this.render(entries);
  }

  updateHistory(entry) {
    if (!entry || !entry.host || !entry.ok) return;
    
    const history = this.history[entry.host] || [];
    const cpu = entry.cpu?.percent ?? null;
    const mem = entry.memory?.percent ?? null;
    
    // Calculate network speed
    let netRx = 0, netTx = 0;
    if (entry.network) {
      const prevNet = (this.netHistory[entry.host] || {}).network || {};
      const prevTime = (this.netHistory[entry.host] || {}).time || 0;
      const timeDiff = (Date.now() - prevTime) / 1000;
      
      if (timeDiff > 0 && timeDiff < 10) {
        Object.entries(entry.network).forEach(([iface, stats]) => {
          if (prevNet[iface]) {
            netRx += (stats.rx_bytes - prevNet[iface].rx_bytes) / timeDiff / (1024 * 1024);
            netTx += (stats.tx_bytes - prevNet[iface].tx_bytes) / timeDiff / (1024 * 1024);
          }
        });
      }
      this.netHistory[entry.host] = { network: entry.network, time: Date.now() };
    }
    
    let gpu = null;
    if (entry.gpus?.length) {
      const utils = entry.gpus.map(g => g.util).filter(v => typeof v === 'number');
      if (utils.length) gpu = utils.reduce((a, b) => a + b, 0) / utils.length;
    }
    
    history.push({ ts: Date.now(), cpu, mem, gpu, netRx: Math.max(0, netRx), netTx: Math.max(0, netTx) });
    if (history.length > this.maxPoints) history.splice(0, history.length - this.maxPoints);
    
    this.history[entry.host] = history;
  }

  render(entries) {
    if (!this.container || !entries.length) return;
    
    const grid = document.createElement('div');
    grid.className = 'host-grid';
    
    const chartsToRender = [];
    
    entries.forEach(entry => {
      const card = this.createHostCard(entry);
      grid.appendChild(card);
      
      const history = this.history[entry.host] || [];
      if (history.length) {
        chartsToRender.push({ host: entry.host, type: 'main' });
        if (history.some(p => p.netRx > 0 || p.netTx > 0)) {
          chartsToRender.push({ host: entry.host, type: 'network' });
        }
      }
    });
    
    this.container.innerHTML = '';
    this.container.appendChild(grid);
    
    // Render charts after DOM update
    requestAnimationFrame(() => {
      chartsToRender.forEach(item => this.renderChart(item.host, item.type));
    });
  }

  createHostCard(entry) {
    const card = document.createElement('div');
    card.className = 'host-card';
    
    let html = `
      <h3>${entry.host || 'Unknown'}</h3>
      <div class="host-meta">${entry.collected ? `Updated ${new Date(entry.collected).toLocaleTimeString()}` : ''}</div>
    `;
    
    if (!entry.ok) {
      html += `<p class="error">Error: ${entry.error || 'Unavailable'}</p>`;
    } else {
      html += `<div class="metric-row">CPU: ${entry.cpu?.percent?.toFixed(1) ?? 'n/a'}%</div>`;
      
      const mem = entry.memory || {};
      html += `<div class="metric-row">Memory: ${mem.used_mb || 0} / ${mem.total_mb || 0} MiB (${mem.percent?.toFixed(1) || 0}%)</div>`;
      if (mem.app_used_mb !== undefined) {
        html += `<div class="metric-row muted" style="font-size:0.85rem;">↳ Apps: ${mem.app_used_mb} MiB, Cache: ${mem.cache_mb} MiB</div>`;
      }
      
      // GPU
      if (entry.gpus?.length) {
        html += '<table class="gpu-table"><tr><th>GPU</th><th>Util%</th><th>Mem%</th><th>Temp</th></tr>';
        entry.gpus.forEach(gpu => {
          html += `<tr>
            <td>${gpu.name || 'GPU ' + gpu.index}</td>
            <td>${gpu.util?.toFixed(1) ?? 'n/a'}</td>
            <td>${gpu.memory_util?.toFixed(1) ?? 'n/a'}</td>
            <td>${gpu.temperature?.toFixed(0) ?? 'n/a'}°C</td>
          </tr>`;
        });
        html += '</table>';
      }
      
      // Disk
      if (entry.disk?.length) {
        html += '<div class="mt-md border-t"><div class="metric-row" style="font-weight:600;">💾 Disk</div>';
        entry.disk.slice(0, 3).forEach(d => {
          const barColor = d.percent > 90 ? '#ef4444' : d.percent > 75 ? '#f59e0b' : '#22c55e';
          html += `<div class="metric-row" style="font-size:0.85rem;">
            <div class="flex-row gap-sm">
              <code style="min-width:60px;font-size:0.75rem;">${d.mount}</code>
              <div class="progress-bar"><div class="progress-bar-fill" style="width:${d.percent}%;background:${barColor};"></div></div>
              <span style="min-width:100px;text-align:right;">${d.used_gb}/${d.total_gb}GB</span>
            </div>
          </div>`;
        });
        html += '</div>';
      }
      
      // Network
      if (entry.network && Object.keys(entry.network).length) {
        const prevNet = (this.netHistory[entry.host] || {}).network || {};
        const prevTime = (this.netHistory[entry.host] || {}).time || 0;
        const timeDiff = (Date.now() - prevTime) / 1000;
        
        html += '<div class="mt-md border-t"><div class="metric-row" style="font-weight:600;">🌐 Network</div>';
        Object.entries(entry.network).slice(0, 4).forEach(([iface, stats]) => {
          let speedText = '';
          if (prevNet[iface] && timeDiff > 0 && timeDiff < 10) {
            const rxSpeed = (stats.rx_bytes - prevNet[iface].rx_bytes) / timeDiff / (1024 * 1024);
            const txSpeed = (stats.tx_bytes - prevNet[iface].tx_bytes) / timeDiff / (1024 * 1024);
            speedText = ` (↓${rxSpeed.toFixed(1)} ↑${txSpeed.toFixed(1)} MB/s)`;
          }
          html += `<div class="metric-row" style="font-size:0.85rem;">
            <code style="min-width:80px;font-size:0.75rem;">${iface}</code>
            <span style="color:#22c55e;">↓${this.formatBytes(stats.rx_bytes)}</span>
            <span style="color:#3b82f6;">↑${this.formatBytes(stats.tx_bytes)}</span>
            <span style="color:#64748b;font-size:0.75rem;">${speedText}</span>
          </div>`;
        });
        html += '</div>';
      }
      
      // Chart placeholders
      const hostId = entry.host.replace(/[^a-zA-Z0-9_-]/g, '_');
      html += `<div class="chart-container"><canvas id="chart-${hostId}"></canvas></div>`;
      const history = this.history[entry.host] || [];
      if (history.some(p => p.netRx > 0 || p.netTx > 0)) {
        html += `<div class="chart-container mt-sm"><canvas id="netchart-${hostId}"></canvas></div>`;
      }
    }
    
    card.innerHTML = html;
    return card;
  }

  renderChart(host, type) {
    const hostId = host.replace(/[^a-zA-Z0-9_-]/g, '_');
    const canvasId = type === 'network' ? `netchart-${hostId}` : `chart-${hostId}`;
    const canvas = document.getElementById(canvasId);
    const history = this.history[host] || [];
    
    if (!canvas || !history.length || typeof Chart === 'undefined') return;
    
    const chartStore = type === 'network' ? this.netCharts : this.charts;
    if (chartStore[host]) chartStore[host].destroy();
    
    const labels = history.map(p => new Date(p.ts).toLocaleTimeString());
    
    let datasets, options;
    
    if (type === 'network') {
      datasets = [
        { label: '↓ Download MB/s', borderColor: '#22c55e', backgroundColor: 'rgba(34,197,94,0.1)', fill: true, tension: 0.2, pointRadius: 0, borderWidth: 2, data: history.map(p => p.netRx || 0) },
        { label: '↑ Upload MB/s', borderColor: '#3b82f6', backgroundColor: 'rgba(59,130,246,0.1)', fill: true, tension: 0.2, pointRadius: 0, borderWidth: 2, data: history.map(p => p.netTx || 0) },
      ];
      const maxVal = Math.max(...history.map(p => Math.max(p.netRx || 0, p.netTx || 0)), 1);
      options = {
        scales: { y: { suggestedMin: 0, suggestedMax: Math.ceil(maxVal * 1.2), beginAtZero: true, title: { display: true, text: 'MB/s' } }, x: { ticks: { maxTicksLimit: 6 } } },
        plugins: { legend: { position: 'bottom' }, title: { display: true, text: '🌐 Network Speed', font: { size: 12 } } },
      };
    } else {
      datasets = [
        { label: 'CPU %', borderColor: '#1b5e20', fill: false, tension: 0.2, pointRadius: 0, borderWidth: 2, data: history.map(p => p.cpu) },
        { label: 'Memory %', borderColor: '#1565c0', fill: false, tension: 0.2, pointRadius: 0, borderWidth: 2, data: history.map(p => p.mem) },
        { label: 'GPU %', borderColor: '#ef6c00', fill: false, tension: 0.2, pointRadius: 0, borderWidth: 2, data: history.map(p => p.gpu) },
      ].filter(ds => ds.data.some(v => typeof v === 'number'));
      options = {
        scales: { y: { suggestedMin: 0, suggestedMax: 100, beginAtZero: true, ticks: { stepSize: 20 } }, x: { ticks: { maxTicksLimit: 6 } } },
        plugins: { legend: { position: 'bottom' } },
      };
    }
    
    chartStore[host] = new Chart(canvas.getContext('2d'), {
      type: 'line',
      data: { labels, datasets },
      options: { responsive: true, maintainAspectRatio: false, animation: false, ...options },
    });
  }

  formatBytes(bytes) {
    if (bytes === 0) return '0 B';
    const k = 1024;
    const sizes = ['B', 'KB', 'MB', 'GB', 'TB'];
    const i = Math.floor(Math.log(bytes) / Math.log(k));
    return parseFloat((bytes / Math.pow(k, i)).toFixed(1)) + ' ' + sizes[i];
  }
}

// ============================================================================
// Cluster Status Manager
// ============================================================================
class ClusterStatusManager {
  constructor(containerId) {
    this.container = document.getElementById(containerId);
    this.stream = null;
  }

  start() {
    this.stream = new SSEStream('/cluster-status-stream',
      (data) => this.render(data),
      {
        onStatus: (status, color) => this.updateSSEStatus(status, color),
      }
    );
    this.stream.start();
  }

  stop() {
    if (this.stream) {
      this.stream.stop();
      this.stream = null;
    }
    if (this.container) {
      this.container.innerHTML = '<div class="empty-state"><p>Cluster monitoring disabled</p></div>';
    }
  }

  updateSSEStatus(status, color) {
    const el = document.getElementById('cluster-sse-status');
    if (el) {
      el.textContent = status ? `● ${status.charAt(0).toUpperCase() + status.slice(1)}` : '';
      el.style.color = color || 'inherit';
    }
  }

  render(data) {
    if (!this.container) return;
    
    if (!data.ok) {
      this.container.innerHTML = `
        <div class="api-status unhealthy">
          <div class="status-indicator red"></div>
          <span>API Server: ${data.api_server?.message || 'Unreachable'}</span>
        </div>
        <div class="empty-state mt-lg"><p>Unable to connect to Kubernetes API server</p></div>
      `;
      return;
    }
    
    const summary = data.summary || {};
    const nodes = data.nodes || [];
    const namespaces = data.namespaces || {};
    
    let html = `
      <div class="api-status healthy">
        <div class="status-indicator green"></div>
        <span>API Server Healthy</span>
        <span class="muted" style="margin-left:auto;font-size:0.8rem;">
          Updated ${new Date(data.collected).toLocaleTimeString()}
        </span>
      </div>
      
      <div class="stat-grid mt-md">
        <div class="summary-card"><div class="value">${nodes.length}</div><div class="label">Nodes</div></div>
        <div class="summary-card"><div class="value ${summary.running_pods === summary.total_pods ? 'success' : 'warning'}">${summary.running_pods}/${summary.total_pods}</div><div class="label">Running Pods</div></div>
        <div class="summary-card"><div class="value ${summary.pending_pods > 0 ? 'warning' : ''}">${summary.pending_pods}</div><div class="label">Pending</div></div>
        <div class="summary-card"><div class="value ${summary.failed_pods > 0 ? 'danger' : ''}">${summary.failed_pods}</div><div class="label">Failed</div></div>
        <div class="summary-card"><div class="value">${summary.total_services}</div><div class="label">Services</div></div>
        <div class="summary-card"><div class="value ${summary.ready_deployments === summary.total_deployments ? 'success' : 'warning'}">${summary.ready_deployments}/${summary.total_deployments}</div><div class="label">Deployments</div></div>
      </div>
      
      <h4 class="mt-lg mb-md" style="color:#334155;">Nodes</h4>
      <div class="node-cards">
        ${nodes.map(node => this.renderNodeCard(node)).join('')}
      </div>
    `;
    
    // Namespaces
    const nsKeys = Object.keys(namespaces);
    if (nsKeys.length) {
      html += '<div class="namespace-section"><h4 style="margin:0 0 0.75rem;color:#334155;">Workloads by Namespace</h4>';
      nsKeys.forEach(ns => {
        html += this.renderNamespace(ns, namespaces[ns]);
      });
      html += '</div>';
    }
    
    this.container.innerHTML = html;
  }

  renderNodeCard(node) {
    const isReady = node.ready;
    return `
      <div class="node-card ${isReady ? 'ready' : 'not-ready'}">
        <div class="node-name" style="display:flex;justify-content:space-between;align-items:center;">
          <div>
            ${node.name}
            <span class="node-badge ${isReady ? 'ready' : 'not-ready'}">${isReady ? 'Ready' : 'Not Ready'}</span>
          </div>
          <div class="node-actions">
            <button class="node-actions-btn" onclick="event.stopPropagation();ClusterUI.toggleNodeMenu('${node.name}')">⋮</button>
            <div class="node-actions-menu" id="node-menu-${node.name}">
              <button onclick="ClusterUI.nodeAction('${node.name}','cordon')">🚫 Cordon</button>
              <button onclick="ClusterUI.nodeAction('${node.name}','uncordon')">✅ Uncordon</button>
              <button class="danger" onclick="if(confirm('Drain ${node.name}?')) ClusterUI.nodeAction('${node.name}','drain')">⚠️ Drain</button>
            </div>
          </div>
        </div>
        <div class="node-info">
          <span><strong>Version:</strong> ${node.version || 'Unknown'}</span>
          <span><strong>CPU:</strong> ${node.cpu || 'N/A'}</span>
          <span><strong>Memory:</strong> ${node.memory || 'N/A'}</span>
        </div>
      </div>
    `;
  }

  renderNamespace(ns, nsData) {
    const podCount = nsData.pods?.length || 0;
    const svcCount = nsData.services?.length || 0;
    const deplCount = nsData.deployments?.length || 0;
    
    let html = `
      <div class="namespace-header" onclick="ClusterUI.toggleNamespace(this)">
        <h4>${ns}</h4>
        <span class="ns-badge">${podCount} pods, ${svcCount} svc, ${deplCount} deploy</span>
        <span class="expand-icon">▼</span>
      </div>
      <div class="namespace-content">
    `;
    
    // Pods
    if (nsData.pods?.length) {
      html += '<table class="resource-table"><tr><th>Pod</th><th>Status</th><th>Ready</th><th>Restarts</th><th></th></tr>';
      nsData.pods.forEach(pod => {
        const statusClass = pod.phase.toLowerCase() === 'running' ? 'running' : pod.phase.toLowerCase() === 'pending' ? 'pending' : 'failed';
        html += `<tr>
          <td>${pod.name.substring(0, 35)}${pod.name.length > 35 ? '...' : ''}</td>
          <td><span class="status-dot ${statusClass}"></span>${pod.phase}</td>
          <td>${pod.ready ? '✓' : '✗'}</td>
          <td>${pod.restarts}</td>
          <td>
            <button class="ops-btn sm secondary" onclick="ClusterUI.showPodLogs('${ns}','${pod.name}')" style="padding:0.2rem 0.4rem;">📋</button>
            <button class="ops-btn sm danger" onclick="ClusterUI.deletePod('${ns}','${pod.name}')" style="padding:0.2rem 0.4rem;">✕</button>
          </td>
        </tr>`;
      });
      html += '</table>';
    }
    
    // Services
    if (nsData.services?.length) {
      html += '<table class="resource-table mt-md"><tr><th>Service</th><th>Type</th><th>Cluster IP</th><th>External IP</th></tr>';
      nsData.services.forEach(svc => {
        html += `<tr>
          <td>${svc.name}</td>
          <td>${svc.type}</td>
          <td style="font-family:monospace;font-size:0.8rem;">${svc.cluster_ip || '-'}</td>
          <td style="font-family:monospace;font-size:0.8rem;">${svc.external_ip || '-'}</td>
        </tr>`;
      });
      html += '</table>';
    }
    
    // Deployments
    if (nsData.deployments?.length) {
      html += '<table class="resource-table mt-md"><tr><th>Deployment</th><th>Ready</th><th>Available</th><th></th></tr>';
      nsData.deployments.forEach(deploy => {
        const isReady = deploy.ready === deploy.replicas && deploy.replicas > 0;
        html += `<tr>
          <td>${deploy.name}</td>
          <td><span class="status-dot ${isReady ? 'ready' : 'not-ready'}"></span>${deploy.ready}/${deploy.replicas}</td>
          <td>${deploy.available}</td>
          <td><button class="ops-btn sm secondary" onclick="ClusterUI.restartDeployment('${ns}','${deploy.name}')">🔄</button></td>
        </tr>`;
      });
      html += '</table>';
    }
    
    html += '</div>';
    return html;
  }
}

// ============================================================================
// Cluster UI Operations (global functions for HTML onclick handlers)
// ============================================================================
const ClusterUI = {
  async nodeAction(node, action) {
    Toast.info(`Running ${action} on ${node}...`);
    try {
      const data = await API.post(`/node/${node}/${action}`);
      Toast.show(data.message, data.success ? 'success' : 'error');
    } catch (err) {
      Toast.error(`Error: ${err}`);
    }
    ClusterUI.closeAllMenus();
  },

  toggleNodeMenu(node) {
    ClusterUI.closeAllMenus();
    const menu = document.getElementById(`node-menu-${node}`);
    if (menu) menu.classList.toggle('show');
  },

  closeAllMenus() {
    document.querySelectorAll('.node-actions-menu').forEach(m => m.classList.remove('show'));
  },

  toggleNamespace(header) {
    header.classList.toggle('collapsed');
    const content = header.nextElementSibling;
    if (content) content.classList.toggle('hidden');
  },

  async restartDeployment(namespace, name) {
    Toast.info(`Restarting ${name}...`);
    const data = await API.post(`/deployment/${namespace}/${name}/restart`);
    Toast.show(data.message, data.success ? 'success' : 'error');
  },

  async deletePod(namespace, name) {
    if (!confirm(`Delete pod ${name}?`)) return;
    Toast.info(`Deleting ${name}...`);
    const data = await API.post(`/pod/${namespace}/${name}/delete`);
    Toast.show(data.message, data.success ? 'success' : 'error');
  },

  async showPodLogs(namespace, name) {
    const modal = document.getElementById('pod-logs-modal');
    const title = document.getElementById('pod-logs-title');
    const content = document.getElementById('pod-logs-content');
    
    if (!modal) return;
    
    title.textContent = `Logs: ${name}`;
    content.textContent = 'Loading...';
    modal.classList.add('show');
    
    try {
      const data = await API.get(`/pod/${namespace}/${name}/logs?tail=200`);
      content.textContent = data.success ? (data.logs || 'No logs') : `Error: ${data.error}`;
      content.scrollTop = content.scrollHeight;
    } catch (err) {
      content.textContent = `Error: ${err}`;
    }
  },

  async wakeCluster(target = 'all') {
    Toast.info(`Sending Wake-on-LAN to ${target}...`);
    try {
      const data = await API.post('/wake', { target });
      if (data.success) {
        Toast.success(`Wake packets sent to: ${data.results.map(r => r.node).join(', ')}`);
      } else {
        Toast.error(`Wake failed: ${data.message}`);
      }
    } catch (err) {
      Toast.error(`Error: ${err}`);
    }
  },

  async runAction(action) {
    Toast.info(`Starting ${action} operation...`);
    const outputEl = document.getElementById('ops-live-output');
    const panel = document.getElementById('ops-output-panel');
    
    if (panel) panel.style.display = 'block';
    if (outputEl) outputEl.textContent = `Running ${action}...\n`;
    
    document.querySelectorAll('.ops-btn').forEach(btn => btn.disabled = true);
    
    try {
      await API.stream(`/run/${action}`, 'POST', {}, (chunk) => {
        if (outputEl) {
          outputEl.textContent += chunk.replace(/\x1b\[[0-9;]*m/g, '');
          outputEl.scrollTop = outputEl.scrollHeight;
        }
      });
      Toast.success(`${action} operation completed!`);
    } catch (err) {
      Toast.error(`Operation failed: ${err}`);
    } finally {
      document.querySelectorAll('.ops-btn').forEach(btn => btn.disabled = false);
    }
  },
};

// Close menus on outside click
document.addEventListener('click', (e) => {
  if (!e.target.closest('.node-actions')) {
    ClusterUI.closeAllMenus();
  }
});

// ============================================================================
// Initialize Everything
// ============================================================================
let llmManager, imagegenManager, hostMetrics, clusterStatus;

document.addEventListener('DOMContentLoaded', () => {
  // Initialize components
  Toast.init();
  Tabs.init();
  
  // Initialize managers
  llmManager = new LLMManager();
  imagegenManager = new ImageGenManager();
  hostMetrics = new HostMetricsManager('host-metrics');
  clusterStatus = new ClusterStatusManager('cluster-status-container');
  
  // Tab callbacks
  Tabs.onActivate('llm', () => {
    llmManager.loadModels();
    llmManager.loadStatus();
  });
  
  Tabs.onActivate('imagegen', () => {
    imagegenManager.loadStatus();
  });
  
  Tabs.onActivate('cluster', () => {
    if (!clusterStatus.stream) {
      clusterStatus.start();
    }
  });
  
  // Start cluster status on load (Ops Center is default tab)
  clusterStatus.start();
  
  Tabs.onActivate('utilization', () => {
    const toggle = document.getElementById('tracking-toggle');
    if (toggle?.checked && !hostMetrics.stream) {
      hostMetrics.start();
    }
  });
  
  // Initialize tracking toggle
  const trackingToggle = document.getElementById('tracking-toggle');
  if (trackingToggle) {
    trackingToggle.addEventListener('change', () => {
      if (trackingToggle.checked) {
        hostMetrics.start();
      } else {
        hostMetrics.stop();
      }
    });
  }
  
  // Initialize cluster tracking toggle
  const clusterToggle = document.getElementById('cluster-tracking-toggle');
  if (clusterToggle) {
    clusterToggle.addEventListener('change', () => {
      if (clusterToggle.checked) {
        clusterStatus.start();
      } else {
        clusterStatus.stop();
      }
    });
    
    // Auto-start cluster status
    if (clusterToggle.checked) {
      clusterStatus.start();
    }
  }
  
  // Initial data load
  setTimeout(async () => {
    await llmManager.loadModels();
    await llmManager.loadStatus();
  }, 1000);
});

// ============================================================================
// Global Function Exports (for onclick handlers in HTML)
// ============================================================================
window.Toast = Toast;
window.Modal = Modal;
window.ClusterUI = ClusterUI;

// LLM functions
window.llmDeploy = (mode) => {
  const model = document.getElementById('llm-model-select')?.value || 'nemotron-nano-30b';
  if (confirm(`Deploy ${model} in ${mode} mode?`)) {
    llmManager.deploy(mode, model);
  }
};
window.llmStart = () => llmManager.start();
window.llmStop = () => { if (confirm('Stop the model?')) llmManager.stop(); };
window.llmDelete = () => { if (confirm('Delete the deployment?')) llmManager.delete(); };
window.llmRestart = () => { if (confirm('Restart vLLM?')) llmManager.restart(); };
window.llmRefreshLogs = () => llmManager.refreshLogs();
window.llmClearChat = () => llmManager.clearChat();
window.llmSendMessage = () => llmManager.sendMessage();

// ImageGen functions
window.imagegenDeploy = () => {
  const model = document.getElementById('imagegen-model-select')?.value || 'qwen-image-2512';
  const replicas = parseInt(document.getElementById('imagegen-replicas')?.value) || 2;
  if (confirm(`Deploy ${model} with ${replicas} replica(s)?`)) {
    imagegenManager.deploy('deploy', model).then(() => imagegenManager.loadStatus());
  }
};
window.imagegenScale = (replicas) => {
  if (confirm(`Scale to ${replicas} replica(s)?`)) {
    imagegenManager.scale(replicas);
  }
};
window.imagegenDelete = () => { if (confirm('Delete deployment?')) imagegenManager.delete(); };
window.imagegenRefreshStatus = () => imagegenManager.loadStatus();
window.imagegenRefreshLogs = () => imagegenManager.refreshLogs();
window.imagegenGenerate = () => imagegenManager.generate();
window.imagegenDownload = () => imagegenManager.download();
window.imagegenClear = () => imagegenManager.clear();

// Cluster operations
window.runClusterAction = (action) => ClusterUI.runAction(action);
window.wakeCluster = (target) => ClusterUI.wakeCluster(target);
window.refreshClusterStatus = () => {
  if (clusterStatus.stream) {
    clusterStatus.stop();
  }
  clusterStatus.start();
  Toast.info('Refreshing cluster status...');
};
window.confirmAction = (action, message) => {
  Modal.confirm(message, () => ClusterUI.runAction(action));
};

// Modal functions
window.hideModal = () => Modal.hide('confirm-modal');
window.hidePodLogsModal = () => Modal.hide('pod-logs-modal');
window.hideOpsOutput = () => {
  const panel = document.getElementById('ops-output-panel');
  if (panel) panel.style.display = 'none';
};

// ============================================================================
// Image Generation History & Gallery
// ============================================================================

let galleryOffset = 0;
const GALLERY_PAGE_SIZE = 20;

window.imagegenLoadStats = async () => {
  try {
    const resp = await fetch('/imagegen/proxy/stats');
    if (!resp.ok) throw new Error('Failed to load stats');
    const data = await resp.json();
    
    if (!data.success) throw new Error(data.error || 'Unknown error');
    
    const stats = data.stats;
    
    // Update totals
    document.getElementById('stats-total').textContent = stats.total_generations || 0;
    
    // Calculate overall avg time
    let totalTime = 0, totalCount = 0;
    if (stats.by_model) {
      for (const [, m] of Object.entries(stats.by_model)) {
        totalTime += (m.avg_time_ms || 0) * (m.count || 0);
        totalCount += m.count || 0;
      }
    }
    const avgTime = totalCount > 0 ? Math.round(totalTime / totalCount) : 0;
    document.getElementById('stats-avg-time').textContent = avgTime ? `${(avgTime/1000).toFixed(1)}s` : '-';
    
    // Stats by model
    const byModelEl = document.getElementById('stats-by-model');
    if (stats.by_model && Object.keys(stats.by_model).length > 0) {
      byModelEl.innerHTML = '<h4 style="font-size:0.85rem;margin-bottom:0.5rem;">By Model</h4>' +
        Object.entries(stats.by_model).map(([model, m]) => `
          <div class="model-stat">
            <span class="model-stat-name">${model}</span>
            <span class="model-stat-info">${m.count} imgs, ${(m.avg_time_ms/1000).toFixed(1)}s avg</span>
          </div>
        `).join('');
    } else {
      byModelEl.innerHTML = '<p class="muted">No data yet</p>';
    }
  } catch (e) {
    console.error('Load stats error:', e);
  }
};

window.imagegenLoadHistory = async () => {
  try {
    const resp = await fetch('/imagegen/proxy/history?limit=10');
    if (!resp.ok) throw new Error('Failed to load history');
    const data = await resp.json();
    
    if (!data.success) throw new Error(data.error || 'Unknown error');
    
    const listEl = document.getElementById('imagegen-history-list');
    
    if (!data.history || data.history.length === 0) {
      listEl.innerHTML = '<p class="muted">No history yet. Generate some images!</p>';
      return;
    }
    
    listEl.innerHTML = data.history.map(h => `
      <div class="history-item" onclick="imagegenShowImage('${h.id}')">
        <img src="/imagegen/proxy/image/${h.id}" class="history-thumb" alt="thumb" 
             onerror="this.style.display='none'">
        <div class="history-details">
          <div class="history-prompt">${escapeHtml(h.prompt.substring(0, 60))}${h.prompt.length > 60 ? '...' : ''}</div>
          <div class="history-meta">
            <span>${h.width}×${h.height}</span>
            <span>${(h.generation_time_ms/1000).toFixed(1)}s</span>
            <span>${formatTimestamp(h.timestamp)}</span>
          </div>
        </div>
      </div>
    `).join('');
  } catch (e) {
    console.error('Load history error:', e);
  }
};

window.imagegenLoadGallery = async (append = false) => {
  try {
    if (!append) galleryOffset = 0;
    
    const modelFilter = document.getElementById('gallery-model-filter')?.value || '';
    const url = `/imagegen/proxy/history?limit=${GALLERY_PAGE_SIZE}&offset=${galleryOffset}${modelFilter ? '&model=' + modelFilter : ''}`;
    
    const resp = await fetch(url);
    if (!resp.ok) throw new Error('Failed to load gallery');
    const data = await resp.json();
    
    if (!data.success) throw new Error(data.error || 'Unknown error');
    
    const galleryEl = document.getElementById('imagegen-gallery');
    const loadMoreBtn = document.getElementById('gallery-load-more');
    
    if (!data.history || data.history.length === 0) {
      if (!append) {
        galleryEl.innerHTML = '<p class="muted">No images yet. Generate some!</p>';
      }
      loadMoreBtn.style.display = 'none';
      return;
    }
    
    const items = data.history.map(h => `
      <div class="gallery-item" onclick="imagegenShowImage('${h.id}')">
        <img src="/imagegen/proxy/image/${h.id}" alt="${escapeHtml(h.prompt.substring(0, 30))}"
             onerror="this.parentElement.style.display='none'">
        <div class="gallery-item-info">
          <div class="gallery-item-time">${formatTimestamp(h.timestamp)}</div>
          <div class="gallery-item-meta">
            <span>${h.width}×${h.height}</span>
            <span>${(h.generation_time_ms/1000).toFixed(1)}s</span>
          </div>
        </div>
      </div>
    `).join('');
    
    if (append) {
      galleryEl.insertAdjacentHTML('beforeend', items);
    } else {
      galleryEl.innerHTML = items;
    }
    
    loadMoreBtn.style.display = data.history.length >= GALLERY_PAGE_SIZE ? 'block' : 'none';
    galleryOffset += data.history.length;
  } catch (e) {
    console.error('Load gallery error:', e);
  }
};

window.imagegenLoadMoreGallery = () => imagegenLoadGallery(true);

window.imagegenShowImage = async (id) => {
  try {
    const resp = await fetch(`/imagegen/proxy/image/${id}/metadata`);
    if (!resp.ok) throw new Error('Failed to load metadata');
    const data = await resp.json();
    
    if (!data.success) throw new Error(data.error || 'Unknown error');
    
    const meta = data.metadata;
    
    // Create modal
    const modal = document.createElement('div');
    modal.className = 'image-modal';
    modal.onclick = (e) => { if (e.target === modal) modal.remove(); };
    
    modal.innerHTML = `
      <button class="image-modal-close" onclick="this.parentElement.remove()">&times;</button>
      <div class="image-modal-content">
        <img src="/imagegen/proxy/image/${id}" alt="Generated image">
        <div class="image-modal-info">
          <h3 style="margin-top:0;">Generation Details</h3>
          <p><strong>Prompt:</strong></p>
          <p style="font-size:0.9rem;background:var(--panel-muted);padding:0.5rem;border-radius:4px;">${escapeHtml(meta.prompt)}</p>
          ${meta.negative_prompt ? `<p><strong>Negative:</strong> ${escapeHtml(meta.negative_prompt)}</p>` : ''}
          <hr style="border:none;border-top:1px solid var(--border);margin:1rem 0;">
          <p><strong>Model:</strong> ${meta.model}</p>
          <p><strong>Resolution:</strong> ${meta.width} × ${meta.height}</p>
          <p><strong>Steps:</strong> ${meta.steps}</p>
          <p><strong>Guidance:</strong> ${meta.guidance_scale}</p>
          <p><strong>Seed:</strong> ${meta.seed}</p>
          <hr style="border:none;border-top:1px solid var(--border);margin:1rem 0;">
          <p><strong>Generation Time:</strong> ${(meta.generation_time_ms/1000).toFixed(2)}s</p>
          <p><strong>Date:</strong> ${new Date(meta.timestamp).toLocaleString()}</p>
          <p><strong>Node:</strong> ${meta.node_name || 'unknown'}</p>
          <p><strong>GPU:</strong> ${meta.gpu_name || 'unknown'}</p>
          <hr style="border:none;border-top:1px solid var(--border);margin:1rem 0;">
          <a href="/imagegen/proxy/image/${id}" download="image-${id.substring(0,8)}.png" 
             class="ops-btn primary w-full" style="text-align:center;text-decoration:none;">
            💾 Download Image
          </a>
        </div>
      </div>
    `;
    
    document.body.appendChild(modal);
  } catch (e) {
    console.error('Show image error:', e);
    Toast.error('Failed to load image details');
  }
};

function escapeHtml(text) {
  const div = document.createElement('div');
  div.textContent = text;
  return div.innerHTML;
}

function formatTimestamp(ts) {
  const d = new Date(ts);
  const now = new Date();
  const diff = now - d;
  
  if (diff < 60000) return 'Just now';
  if (diff < 3600000) return `${Math.floor(diff/60000)}m ago`;
  if (diff < 86400000) return `${Math.floor(diff/3600000)}h ago`;
  if (diff < 604800000) return `${Math.floor(diff/86400000)}d ago`;
  return d.toLocaleDateString();
}

// Auto-load stats and history when Image Gen tab is activated
const originalImagegenTabActivate = Tabs.onActivate;
Tabs.onActivate('imagegen', () => {
  imagegenManager.loadStatus();
  imagegenLoadStats();
  imagegenLoadHistory();
  imagegenLoadGallery();
});
