export function shouldShowRemoteTeamAdvanceNotice({actorUserId,sessionUserId,isAdmin,isHost,player,courtNumber}){
  if(actorUserId===sessionUserId)return false;
  return Boolean(isAdmin||isHost||(player&&(player.status!=='current'||player.court_number===courtNumber)));
}

export function shouldShowTeamCompletionNotice({isOperator,currentUserNeedsRejoin}){
  return isOperator||!currentUserNeedsRejoin;
}
