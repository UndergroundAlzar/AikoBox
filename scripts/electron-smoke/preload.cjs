'use strict'

const { contextBridge, ipcRenderer } = require('electron')

const INVOKE_CHANNEL = 'aikobox-electron-smoke-invoke'
const SEND_CHANNEL = 'aikobox-electron-smoke-send'
const RENDERER_ERROR_CHANNEL = 'aikobox-electron-smoke-renderer-error'
const listeners = new Map()

const electron = {
  ipcRenderer: {
    invoke: (channel) => ipcRenderer.invoke(INVOKE_CHANNEL, channel),
    send: (channel) => ipcRenderer.send(SEND_CHANNEL, channel),
    on: (channel, listener) => {
      let channelListeners = listeners.get(channel)
      if (!channelListeners) {
        channelListeners = new Set()
        listeners.set(channel, channelListeners)
      }
      channelListeners.add(listener)
    },
    removeListener: (channel, listener) => {
      const channelListeners = listeners.get(channel)
      channelListeners?.delete(listener)
      if (channelListeners?.size === 0) listeners.delete(channel)
    },
    removeAllListeners: (channel) => {
      listeners.delete(channel)
    }
  },
  process: { platform: 'win32' }
}

const api = {
  webUtils: {
    getPathForFile: () => {
      throw new Error('SYSTEM_SIDE_EFFECT_BLOCKED:file-capability')
    }
  }
}

contextBridge.exposeInMainWorld('electron', electron)
contextBridge.exposeInMainWorld('api', api)

window.addEventListener('error', () => {
  ipcRenderer.send(RENDERER_ERROR_CHANNEL, 'window-error')
})
window.addEventListener('unhandledrejection', () => {
  ipcRenderer.send(RENDERER_ERROR_CHANNEL, 'unhandled-rejection')
})
