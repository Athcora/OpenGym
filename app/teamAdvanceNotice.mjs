export function shouldShowRemoteTeamAdvanceNotice({actorUserId,sessionUserId,isAdmin,isHost,player,courtNumber}){
  if(actorUserId===sessionUserId)return false;
  return Boolean(isAdmin||isHost||(player&&(player.status!=='current'||player.court_number===courtNumber)));
}

export function shouldShowTeamCompletionNotice({isOperator,currentUserNeedsRejoin}){
  // Operators keep the completion modal even when their own account is also
  // included in the rejoin prompts, so they can immediately correct a mistake.
  return Boolean(isOperator)||!currentUserNeedsRejoin;
}
