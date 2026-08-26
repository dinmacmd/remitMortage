import React from 'react';
import { useWidgetStore, WidgetId } from '../../app/stores/useWidgetStore';

interface WidgetSettingsModalProps {
  isOpen: boolean;
  onClose: () => void;
}

const WIDGET_LABELS: Record<WidgetId, string> = {
  'quick-metrics': 'Quick Metrics',
  'yield-estimator': 'Yield & APY Estimator',
  'credit-recovery': 'Credit Score Recovery',
  'savings-loan': 'Savings & Loan Status',
  'milestones': 'Milestone Timeline',
};

export function WidgetSettingsModal({ isOpen, onClose }: WidgetSettingsModalProps) {
  const { visibility, toggleVisibility, resetLayout } = useWidgetStore();

  if (!isOpen) return null;

  return (
    <div className="fixed inset-0 z-[60] flex items-center justify-center p-4 bg-black/60 backdrop-blur-sm">
      <div className="w-full max-w-md bg-slate-900 border border-slate-800 rounded-2xl shadow-2xl p-6">
        <div className="flex justify-between items-center mb-6">
          <h2 className="text-xl font-bold text-white">Dashboard Layout</h2>
          <button onClick={onClose} className="text-slate-400 hover:text-white">
            <svg width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
              <path d="M18 6L6 18M6 6l12 12" />
            </svg>
          </button>
        </div>

        <div className="space-y-4 mb-8">
          <h3 className="text-sm font-semibold text-slate-400 uppercase tracking-wider">Visible Widgets</h3>
          <div className="space-y-2">
            {(Object.keys(WIDGET_LABELS) as WidgetId[]).map((id) => (
              <label key={id} className="flex items-center gap-3 p-3 bg-slate-800/50 rounded-lg cursor-pointer hover:bg-slate-800 transition-colors">
                <input
                  type="checkbox"
                  checked={visibility[id]}
                  onChange={() => toggleVisibility(id)}
                  className="w-5 h-5 rounded border-slate-600 bg-slate-900 text-cyan-500 focus:ring-cyan-500/50 focus:ring-offset-slate-900"
                />
                <span className="text-slate-200">{WIDGET_LABELS[id]}</span>
              </label>
            ))}
          </div>
        </div>

        <div className="flex items-center justify-between border-t border-slate-800 pt-6">
          <button
            onClick={() => {
              resetLayout();
              onClose();
            }}
            className="text-sm font-medium text-slate-400 hover:text-white transition-colors"
          >
            Reset to Default
          </button>
          <button
            onClick={onClose}
            className="px-6 py-2 bg-cyan-500 hover:bg-cyan-400 text-slate-900 font-bold rounded-full transition-colors"
          >
            Done
          </button>
        </div>
      </div>
    </div>
  );
}
