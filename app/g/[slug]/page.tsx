import AppErrorBoundary from "../../AppErrorBoundary";
import WaitlistApp from "../../WaitlistApp";
import "../../waitlist.css";
import "../../advanced.css";
import "../../icon-fixes.css";

export default async function FacilityQueuePage({params}:{params:Promise<{slug:string}>}) {
  const {slug}=await params;
  return <AppErrorBoundary><WaitlistApp initialFacilitySlug={slug} /></AppErrorBoundary>;
}
