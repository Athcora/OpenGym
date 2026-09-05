"use client";

import React from "react";

type State = { failed: boolean };

export default class AppErrorBoundary extends React.Component<React.PropsWithChildren, State> {
  state: State = { failed: false };

  static getDerivedStateFromError(): State {
    return { failed: true };
  }

  componentDidCatch() {
    const key = "opengym-last-crash-recovery";
    const lastRecovery = Number(sessionStorage.getItem(key) || 0);
    if (Date.now() - lastRecovery < 15_000) return;
    sessionStorage.setItem(key, String(Date.now()));
    const next = new URL(window.location.href);
    next.searchParams.set("recover", String(Date.now()));
    window.location.replace(next.toString());
  }

  render() {
    if (!this.state.failed) return this.props.children;
    return (
      <main className="app-crash-recovery" role="alert">
        <img src="/open-gym-app-icon.png" alt="" />
        <h1>OpenGym needs to refresh</h1>
        <p>Your waitlist position is safe. Reload to continue.</p>
        <button onClick={() => window.location.reload()}>Reload OpenGym</button>
      </main>
    );
  }
}
