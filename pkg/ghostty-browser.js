// Ghostty Browser Runtime JavaScript Integration
// This file provides the JavaScript glue code for the WebAssembly browser runtime

(function() {
    'use strict';
    
    // Global Ghostty namespace
    window.Ghostty = window.Ghostty || {};
    
    /**
     * WebGL Context Management
     */
    Ghostty.WebGL = {
        contexts: new Map(),
        currentContext: null,
        
        /**
         * Initialize WebGL context for a canvas
         */
        init: function(canvasId, width, height) {
            const canvas = document.getElementById(canvasId);
            if (!canvas) {
                console.error('Canvas not found:', canvasId);
                return null;
            }
            
            // Get WebGL 2.0 context
            const gl = canvas.getContext('webgl2', {
                antialias: false,
                alpha: true,
                depth: false,
                stencil: false,
                preserveDrawingBuffer: false,
                powerPreference: 'high-performance'
            });
            
            if (!gl) {
                console.error('WebGL 2.0 not supported');
                return null;
            }
            
            // Set canvas size
            canvas.width = width;
            canvas.height = height;
            
            // Store context
            const ctxId = Math.random().toString(36);
            this.contexts.set(ctxId, {
                gl: gl,
                canvas: canvas,
                programs: new Map(),
                shaders: new Map(),
                buffers: new Map(),
                textures: new Map(),
                framebuffers: new Map()
            });
            
            this.currentContext = ctxId;
            
            // Setup initial state
            gl.enable(gl.BLEND);
            gl.blendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA);
            gl.viewport(0, 0, width, height);
            
            console.log('WebGL context initialized:', ctxId, width + 'x' + height);
            return ctxId;
        },
        
        /**
         * Get current WebGL context
         */
        getCurrentContext: function() {
            if (!this.currentContext) return null;
            return this.contexts.get(this.currentContext);
        },
        
        /**
         * Clear the screen
         */
        clear: function(ctxId, r, g, b, a) {
            const ctx = this.contexts.get(ctxId);
            if (!ctx) {
                console.error('Context not found:', ctxId);
                return;
            }
            
            const {gl} = ctx;
            gl.clearColor(r, g, b, a);
            gl.clear(gl.COLOR_BUFFER_BIT);
        },
        
        /**
         * Present frame (equivalent to swap buffers)
         */
        present: function(ctxId) {
            // WebGL doesn't have explicit swap buffers
            // The browser handles presentation automatically
            // This function is here for API compatibility
        },
        
        /**
         * Resize WebGL context
         */
        resize: function(ctxId, width, height) {
            const ctx = this.contexts.get(ctxId);
            if (!ctx) {
                console.error('Context not found:', ctxId);
                return;
            }
            
            ctx.canvas.width = width;
            ctx.canvas.height = height;
            ctx.gl.viewport(0, 0, width, height);
        },
        
        /**
         * Deinitialize WebGL context
         */
        deinit: function(ctxId) {
            const ctx = this.contexts.get(ctxId);
            if (!ctx) return;
            
            // Clean up WebGL resources
            const {gl} = ctx;
            
            // Delete programs
            for (const program of ctx.programs.values()) {
                gl.deleteProgram(program);
            }
            
            // Delete shaders
            for (const shader of ctx.shaders.values()) {
                gl.deleteShader(shader);
            }
            
            // Delete buffers
            for (const buffer of ctx.buffers.values()) {
                gl.deleteBuffer(buffer);
            }
            
            // Delete textures
            for (const texture of ctx.textures.values()) {
                gl.deleteTexture(texture);
            }
            
            // Delete framebuffers
            for (const framebuffer of ctx.framebuffers.values()) {
                gl.deleteFramebuffer(framebuffer);
            }
            
            this.contexts.delete(ctxId);
            
            if (this.currentContext === ctxId) {
                this.currentContext = null;
            }
            
            console.log('WebGL context destroyed:', ctxId);
        }
    };
    
    /**
     * Console Logging Integration
     */
    Ghostty.log = function(level, message) {
        const levels = ['debug', 'info', 'warn', 'error'];
        const logLevel = levels[level] || 'info';
        console[logLevel]('[Ghostty]', message);
    };
    
    /**
     * Canvas Context Management
     */
    Ghostty.Canvas = {
        contexts: new Map(),
        
        /**
         * Get canvas WebGL context
         */
        getContext: function(canvasId) {
            const canvas = document.getElementById(canvasId);
            if (!canvas) {
                console.error('Canvas not found:', canvasId);
                return null;
            }
            
            // Return existing context or create new one
            if (this.contexts.has(canvasId)) {
                return this.contexts.get(canvasId);
            }
            
            // Create WebGL 2.0 context
            const gl = canvas.getContext('webgl2', {
                antialias: false,
                alpha: true,
                depth: false,
                stencil: false,
                preserveDrawingBuffer: false,
                powerPreference: 'high-performance'
            });
            
            if (!gl) {
                console.error('WebGL 2.0 not supported for canvas:', canvasId);
                return null;
            }
            
            this.contexts.set(canvasId, gl);
            return gl;
        },
        
        /**
         * Set canvas size
         */
        setSize: function(canvasId, width, height) {
            const canvas = document.getElementById(canvasId);
            if (!canvas) {
                console.error('Canvas not found:', canvasId);
                return;
            }
            
            canvas.width = width;
            canvas.height = height;
            
            // Update WebGL viewport if context exists
            const gl = this.contexts.get(canvasId);
            if (gl) {
                gl.viewport(0, 0, width, height);
            }
            
            console.log('Canvas resized:', canvasId, width + 'x' + height);
        }
    };
    
    /**
     * Browser Event Callbacks
     */
    Ghostty.callbacks = {
        /**
         * Focus callback - called when terminal gains/loses focus
         */
        focus: null,
        
        /**
         * Resize callback - called when terminal is resized
         */
        resize: null,
        
        /**
         * Set focus callback
         */
        setFocusCallback: function(callback) {
            this.focus = callback;
            
            // Listen to window focus events
            window.addEventListener('focus', function() {
                if (this.focus) this.focus(true);
            }.bind(this));
            
            window.addEventListener('blur', function() {
                if (this.focus) this.focus(false);
            }.bind(this));
        },
        
        /**
         * Set resize callback
         */
        setResizeCallback: function(callback) {
            this.resize = callback;
            
            // Listen to window resize events
            window.addEventListener('resize', function() {
                if (this.resize) {
                    // Get terminal dimensions
                    const terminal = document.getElementById('ghostty-terminal');
                    if (terminal) {
                        const rect = terminal.getBoundingClientRect();
                        this.resize(Math.floor(rect.width), Math.floor(rect.height));
                    }
                }
            }.bind(this));
        }
    };
    
    /**
     * Clipboard Integration
     */
    Ghostty.clipboard = {
        /**
         * Read from clipboard (requires user permission)
         */
        read: function(callback) {
            if (!navigator.clipboard) {
                console.warn('Clipboard API not available');
                if (callback) callback(null);
                return;
            }
            
            navigator.clipboard.readText()
                .then(function(text) {
                    if (callback) callback(text);
                })
                .catch(function(err) {
                    console.error('Failed to read clipboard:', err);
                    if (callback) callback(null);
                });
        },
        
        /**
         * Write to clipboard (requires user permission)
         */
        write: function(text) {
            if (!navigator.clipboard) {
                console.warn('Clipboard API not available');
                return;
            }
            
            navigator.clipboard.writeText(text)
                .catch(function(err) {
                    console.error('Failed to write clipboard:', err);
                });
        }
    };
    
    /**
     * Animation Frame Integration
     */
    Ghostty.animation = {
        /**
         * Request animation frame callback
         */
        requestFrame: function(callback) {
            return requestAnimationFrame(callback);
        },
        
        /**
         * Cancel animation frame callback
         */
        cancelFrame: function(id) {
            cancelAnimationFrame(id);
        }
    };
    
    /**
     * C API Functions (called from Zig/WASM)
     * These are the extern functions declared in browser.zig
     */
    
    // WebGL CAPI functions
    window.ghostty_js_webgl_init = function(canvasId, width, height) {
        return Ghostty.WebGL.init(canvasId, width, height);
    };
    
    window.ghostty_js_webgl_resize = function(ctxId, width, height) {
        Ghostty.WebGL.resize(ctxId, width, height);
    };
    
    window.ghostty_js_webgl_clear = function(ctxId, r, g, b, a) {
        Ghostty.WebGL.clear(ctxId, r, g, b, a);
    };
    
    window.ghostty_js_webgl_present = function(ctxId) {
        Ghostty.WebGL.present(ctxId);
    };
    
    window.ghostty_js_webgl_deinit = function(ctxId) {
        Ghostty.WebGL.deinit(ctxId);
    };

    // UTF-8 string conversion from WASM memory
    const UTF8ToString = (ptr) => {
        if (!ptr) return '';

        // Find string length
        let len = 0;
        while (Module.HEAPU8[ptr + len] !== 0) len++;

        // Convert to string
        const arr = new Uint8Array(Module.HEAPU8.buffer, ptr, len);
        return new TextDecoder().decode(arr);
    };

    // Logging CAPI functions
    window.ghostty_js_log = function(level, message) {
        const msg = message ? UTF8ToString(message) : '';
        Ghostty.log(level, msg);
    };
    
    // Canvas CAPI functions
    window.ghostty_js_get_canvas_context = function(canvasId) {
        const id = UTF8ToString(canvasId);
        return Ghostty.Canvas.getContext(id);
    };
    
    window.ghostty_js_set_canvas_size = function(canvasId, width, height) {
        const id = UTF8ToString(canvasId);
        Ghostty.Canvas.setSize(id, width, height);
    };
    
    // Callback CAPI functions
    window.ghostty_js_set_focus_callback = function(callback) {
        Ghostty.callbacks.setFocusCallback(callback);
    };
    
    window.ghostty_js_set_resize_callback = function(callback) {
        Ghostty.callbacks.setResizeCallback(callback);
    };
    
    // Animation frame CAPI functions
    window.ghostty_js_request_animation_frame = function(callback) {
        return Ghostty.animation.requestFrame(callback);
    };
    
    // Clipboard CAPI functions
    window.ghostty_js_read_clipboard = function(callback) {
        Ghostty.clipboard.read(function(text) {
            if (callback && text) {
                callback(text);
            } else if (callback) {
                callback(null);
            }
        });
    };
    
    window.ghostty_js_write_clipboard = function(content) {
        const text = UTF8ToString(content);
        Ghostty.clipboard.write(text);
    };
    
    /**
     * Terminal Integration Helpers
     */
    
    Ghostty.terminal = {
        /**
         * Initialize terminal in a container
         */
        init: function(containerId, options) {
            const container = document.getElementById(containerId);
            if (!container) {
                console.error('Container not found:', containerId);
                return false;
            }
            
            // Create canvas element
            const canvas = document.createElement('canvas');
            canvas.id = 'ghostty-canvas';
            canvas.style.width = '100%';
            canvas.style.height = '100%';
            canvas.style.display = 'block';
            
            // Set initial size
            const rect = container.getBoundingClientRect();
            canvas.width = rect.width * window.devicePixelRatio;
            canvas.height = rect.height * window.devicePixelRatio;
            
            container.appendChild(canvas);
            
            console.log('Ghostty terminal initialized in:', containerId);
            return true;
        },
        
        /**
         * Send input to terminal
         */
        sendInput: function(input) {
            // This would call the WASM function to send input
            console.log('Terminal input:', input);
        },
        
        /**
         * Resize terminal
         */
        resize: function(width, height) {
            const canvas = document.getElementById('ghostty-canvas');
            if (canvas) {
                canvas.width = width * window.devicePixelRatio;
                canvas.height = height * window.devicePixelRatio;
                
                // Notify WASM about resize
                if (window.ghostty_resize_callback) {
                    window.ghostty_resize_callback(width, height);
                }
            }
        }
    };
    
    /**
     * Global initialization
     */
    console.log('Ghostty Browser Runtime loaded');
    
})();