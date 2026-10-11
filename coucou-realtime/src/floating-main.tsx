import React from 'react';
import ReactDOM from 'react-dom/client';
import { FloatingBar } from './components/floating/FloatingBar';
import './index.css';

ReactDOM.createRoot(document.getElementById('floating-root') as HTMLElement).render(
  <React.StrictMode>
    <FloatingBar />
  </React.StrictMode>
);
