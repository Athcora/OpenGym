"use client";

import { useEffect } from "react";
import WaitlistApp from "./WaitlistApp";
import "./waitlist.css";
import "./advanced.css";
import "./icon-fixes.css";

export default function Home() {
  useEffect(() => {
    if ("serviceWorker" in navigator) {
      void navigator.serviceWorker.register("/sw.js");
    }
  }, []);

  return <WaitlistApp />;
}
