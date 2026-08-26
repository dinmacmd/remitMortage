import { create } from 'zustand';
import { persist } from 'zustand/middleware';

export type WidgetId = 'yield-summary' | 'loan-status' | 'notifications';

export interface WidgetState {
  order: WidgetId[];
  visibility: Record<WidgetId, boolean>;
  setOrder: (newOrder: WidgetId[]) => void;
  toggleVisibility: (id: WidgetId) => void;
  resetLayout: () => void;
}

const defaultOrder: WidgetId[] = ['yield-summary', 'loan-status', 'notifications'];
const defaultVisibility: Record<WidgetId, boolean> = {
  'yield-summary': true,
  'loan-status': true,
  'notifications': true,
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
