import { ElectronAPI } from '@electron-toolkit/preload'
import type { AthenaApi } from './index'

declare global {
  interface Window {
    electron: ElectronAPI
    api: AthenaApi
  }
}
