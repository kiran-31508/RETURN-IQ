import type { Metadata } from "next";
import "./globals.css";
export const metadata: Metadata = {
  title: "ReturnIQ | Returns Command Center",
  description: "Reverse logistics recovery and supplier quality command center."
};
export default function RootLayout({ children }: { children: React.ReactNode }) {
  return <html lang="en"><body>{children}</body></html>;
}