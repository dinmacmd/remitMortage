import type { Metadata, Viewport } from "next";
import { WalletProvider } from "../context/WalletContext";
import "./globals.css";
import { ContractRegistryProvider } from "@/context/ContractRegistryContext";
import { ThemeProvider } from "@/context/ThemeContext";
import { AuthProvider } from "@/context/AuthContext";
import { NotificationProvider } from "@/context/NotificationContext";
import { NotificationLayer } from "@/components/NotificationLayer";
import { ToastProvider } from "@/context/ToastContext";
import { IdleSessionProvider } from "@/context/IdleSessionContext";
import { KeyboardShortcutsProvider } from "@/context/KeyboardShortcutsContext";
import { ToastContainer } from "@/components/ToastContainer";
import { HotToaster } from "@/components/HotToaster";
import WalletBanner from "@/components/WalletBanner";
import Footer from "@/components/Footer";
import { NextIntlClientProvider } from "next-intl";
import { getLocale, getMessages } from "next-intl/server";

const BASE_URL = process.env.NEXT_PUBLIC_BASE_URL ?? "https://remitmortgage.com";

const TITLE = "RemitMortgage — Remittance-Backed Property Financing on Stellar";
const DESCRIPTION =
  "Turn your verified remittance history into a pathway to homeownership. Save, borrow, and build — all settled in USDC on the Stellar network.";

export const viewport: Viewport = {
  width: "device-width",
  initialScale: 1,
  themeColor: "#060913",
};

export const metadata: Metadata = {
  metadataBase: new URL(BASE_URL),
  title: {
    default: TITLE,
    template: "%s | RemitMortgage",
  },
  description: DESCRIPTION,
  keywords: [
    "remittance",
    "mortgage",
    "Stellar",
    "Soroban",
    "USDC",
    "DeFi",
    "property financing",
    "diaspora",
  ],
  authors: [{ name: "AstronLabs", url: BASE_URL }],
  creator: "AstronLabs",
  openGraph: {
    type: "website",
    url: BASE_URL,
    siteName: "RemitMortgage",
    title: TITLE,
    description: DESCRIPTION,
    images: [
      {
        url: "/og-image.png",
        width: 1200,
        height: 630,
        alt: "RemitMortgage — Remittance-Backed Property Financing on Stellar",
      },
    ],
    locale: "en_US",
  },
  twitter: {
    card: "summary_large_image",
    title: TITLE,
    description: DESCRIPTION,
    images: ["/og-image.png"],
    creator: "@remitmortgage",
    site: "@remitmortgage",
  },
  robots: {
    index: true,
    follow: true,
    googleBot: {
      index: true,
      follow: true,
      "max-snippet": -1,
      "max-image-preview": "large",
    },
  },
  alternates: {
    canonical: BASE_URL,
  },
};

export default async function RootLayout({
  children,
}: Readonly<{
  children: React.ReactNode;
}>) {
  const locale = await getLocale();
  const messages = await getMessages();

  return (
    <html lang={locale} dir={locale === "ar" ? "rtl" : "ltr"} suppressHydrationWarning>
      <head>
        <script
          dangerouslySetInnerHTML={{
            __html: `
              (function() {
                try {
                  var theme = localStorage.getItem("remitmortgage-theme");
                  if (theme === "light" || theme === "dark") {
                    document.documentElement.setAttribute("data-theme", theme);
                  }
                } catch (e) {}
              })();
            `,
          }}
        />
      </head>
      <body className="min-h-screen bg-[#060913] text-slate-100 font-sans antialiased flex flex-col justify-between">
        <NextIntlClientProvider messages={messages} locale={locale}>
          <WalletBanner />
          <ThemeProvider>
            <WalletProvider>
              <ContractRegistryProvider>
              <AuthProvider>
              <NotificationProvider>
                <ToastProvider>
                  <IdleSessionProvider>
                    <KeyboardShortcutsProvider>
                      <div className="flex-1">{children}</div>
                      <Footer />
                      <NotificationLayer />
                      <ToastContainer />
                      <HotToaster />
                    </KeyboardShortcutsProvider>
                  </IdleSessionProvider>
                </ToastProvider>
                </NotificationProvider>
              </AuthProvider>
              </ContractRegistryProvider>
            </WalletProvider>
          </ThemeProvider>
        </NextIntlClientProvider>
      </body>
    </html>
  );
}
