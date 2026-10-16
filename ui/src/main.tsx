// Mounts the console into index.html. StrictMode runs effects twice while developing, which
// checks that every effect cleans up after itself (wallet discovery, the refresh timer).
import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import App from './App'
import './styles.css'

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <App />
  </StrictMode>,
)
