"use client";

import AppErrorBoundary from "../../AppErrorBoundary";
import WaitlistApp from "../../WaitlistApp";
import "../../waitlist.css";
import "../../advanced.css";
import "../../icon-fixes.css";

export default function FacilityQueuePage() {
  return <AppErrorBoundary><WaitlistApp /></AppErrorBoundary>;
}
