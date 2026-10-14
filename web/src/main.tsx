import React from 'react';
import { createRoot } from 'react-dom/client';
import { BrowserRouter } from 'react-router-dom';
import { registerSW } from 'virtual:pwa-register';
import './styles.css';
import { App } from './App';
import { AppProvider } from './lib/session';
import { ToastProvider } from './lib/toast';
import { WizardProvider } from './lib/wizard';

registerSW({ immediate: true });
createRoot(document.getElementById('root')!).render(
  <React.StrictMode>
    <BrowserRouter>
      <ToastProvider>
        <AppProvider>
          <WizardProvider>
            <App />
          </WizardProvider>
        </AppProvider>
      </ToastProvider>
    </BrowserRouter>
  </React.StrictMode>
);
