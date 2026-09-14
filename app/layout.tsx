import type { Metadata } from "next";
import "./globals.css";

export const metadata: Metadata = {
  title: "OpenGym Volleyball Waitlist",
  description: "Join the live OpenGym volleyball queue from your phone.",
  manifest: "/manifest.webmanifest",
  icons: { icon: "/open-gym-app-icon.png", apple: "/open-gym-app-icon.png" },
};

export default function RootLayout({
  children,
}: Readonly<{
  children: React.ReactNode;
}>) {
  return (
    <html lang="en">
      <head>
        <script dangerouslySetInnerHTML={{__html:`(()=>{let recovering=false;addEventListener('error',event=>{const target=event.target;const asset=target&&(target.src||target.href);if(recovering||typeof asset!=='string'||!asset.includes('/assets/'))return;const now=Date.now();const last=Number(sessionStorage.getItem('opengym-asset-recovery')||0);if(now-last<10000)return;recovering=true;sessionStorage.setItem('opengym-asset-recovery',String(now));const next=new URL(location.href);next.searchParams.set('_refresh',String(now));location.replace(next.href)},true)})()`}} />
      </head>
      <body className="antialiased">
        {children}
      </body>
    </html>
  );
}
