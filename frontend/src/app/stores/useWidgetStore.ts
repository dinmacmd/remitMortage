import { create } from 'zustand';
import { persist } from 'zustand/middleware';

export type WidgetId =
  | 'quick-metrics'
  | 'yield-estimator'
  | 'credit-recovery'
  | 'savings-loan'
  | 'milestones';

export interface WidgetState {
  order: WidgetId[];
  visibility: Record<WidgetId, boolean>;
  setOrder: (newOrder: WidgetId[]) => void;
  toggleVisibility: (id: WidgetId) => void;
  resetLayout: () => void;
}

const defaultOrder: WidgetId[] = [
  'quick-metrics',
  'yield-estimator',
  'credit-recovery',
  'savings-loan',
  'milestones',
];
const defaultVisibility: Record<WidgetId, boolean> = {
  'quick-metrics': true,
  'yield-estimator': true,
  'credit-recovery': true,
  'savings-loan': true,
  'milestones': true,
};

export const useWidgetStore = create<WidgetState>()(
  persist(
    (set) => ({
      order: defaultOrder,
      visibility: defaultVisibility,
      setOrder: (newOrder) => set({ order: newOrder }),
      toggleVisibility: (id) =>
        set((state) => ({
          visibility: {
            ...state.visibility,
            [id]: !state.visibility[id],
          },
        })),
      resetLayout: () =>
        set({
          order: defaultOrder,
          visibility: defaultVisibility,
        }),
    }),
    {
      name: 'dashboard-widget-layout', // unique name for localStorage key
    }
  )
);
