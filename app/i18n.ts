export type AppLanguage = 'en'|'es'|'zh-CN';

type TranslationMap = Record<string,string>;

const es:TranslationMap={
  'Log out':'Cerrar sesión','Log out?':'¿Cerrar sesión?','Enable alerts':'Activar alertas','Your actions':'Tus acciones','Next game':'Siguiente juego','Sit out':'Descansar','Leave':'Salir','Remove':'Eliminar','Past games':'Juegos anteriores','Waitlist':'Lista de espera','No one waiting':'Nadie esperando','Players will appear here.':'Los jugadores aparecerán aquí.','Live':'En vivo','Group Up':'Agruparse','Projected:':'Proyección:','You':'Tú','Add player':'Agregar jugador','History':'Historial','Members':'Miembros','Undo':'Deshacer','Redo':'Rehacer','Reset waitlist':'Reiniciar lista','Regular waitlist':'Lista regular','Rejoin waitlist':'Lista de reingreso','Teams mode':'Modo equipos','Rejoin requests':'Solicitudes de reingreso','Set facility location':'Establecer ubicación','Update facility location':'Actualizar ubicación','Restricted Members':'Miembros restringidos','Back to waitlist':'Volver a la lista','Go back':'Volver','Continue as guest':'Continuar como invitado','Sign in':'Iniciar sesión','Create account':'Crear cuenta','Admin':'Administrador','Join waitlist':'Unirse a la lista','First name':'Nombre','Last initial or name':'Inicial o apellido','optional':'opcional','What should we call you?':'¿Cómo debemos llamarte?','PLAYER DETAILS':'DATOS DEL JUGADOR','Your name is added to the waitlist as soon as you continue.':'Tu nombre se agrega a la lista cuando continúas.','I acknowledge':'Entiendo','BEFORE YOU START':'ANTES DE EMPEZAR','QUICK TOUR':'RECORRIDO RÁPIDO','Skip tutorial':'Saltar tutorial','Back':'Atrás','Next':'Siguiente','Finish':'Finalizar','Your controls':'Tus controles','Who is playing now':'Quién juega ahora','Your place in line':'Tu lugar en la fila','Groups and past games':'Grupos y juegos anteriores','Cancel':'Cancelar','OK':'Aceptar','Done':'Listo','Game history':'Historial de juegos','No completed games yet.':'Todavía no hay juegos completados.','Notifications are on':'Las notificaciones están activadas','ADMIN ACCESS':'ACCESO DE ADMINISTRADOR','Manage OpenGym':'Administrar OpenGym','Password':'Contraseña','Username':'Usuario','Email address':'Correo electrónico','Welcome back':'Bienvenido de nuevo','Create your OpenGym account':'Crea tu cuenta de OpenGym','Email me a sign-in link':'Enviarme un enlace','ACCOUNT SIGN IN':'INICIO DE SESIÓN','CREATE ACCOUNT':'CREAR CUENTA','Rejoin':'Reingresar','Do you want to rejoin?':'¿Quieres reingresar?','REJOIN WAITLIST':'REINGRESAR A LA LISTA','Quick tour':'Recorrido rápido','Sit Out skips one game. Leave removes you. When you are playing, Next Game appears here.':'Descansar omite un juego. Salir te elimina. Cuando estés jugando, aquí aparecerá Siguiente juego.','The players in this card are in the current game. Only they—and admins—can start the next game.':'Los jugadores de esta tarjeta están en el juego actual. Solo ellos y los administradores pueden iniciar el siguiente.','Your number is your queue position. When you are waiting, your projected game appears beside your name.':'Tu número indica tu posición. Mientras esperas, el juego proyectado aparece junto a tu nombre.','Use Group Up beside another player to play together. Past Games shows who has already played.':'Usa Agruparse junto a otro jugador para jugar juntos. Juegos anteriores muestra quién ya jugó.','This will remove you from the waitlist and sign you out.':'Esto te eliminará de la lista y cerrará tu sesión.','Next Game affects everyone':'Siguiente juego afecta a todos','This button appears only when you are in the current game. Pressing it ends that game, advances the entire queue, and notifies every player—so use it only when the game is truly over.':'Este botón aparece solo cuando estás en el juego actual. Al presionarlo, termina el juego, avanza toda la fila y notifica a todos; úsalo solo cuando el juego realmente haya terminado.','Sit Out affects only you':'Descansar solo te afecta a ti','Sit Out makes only you skip the next game. Everyone else keeps their order. After skipping one game, you receive priority for the following game.':'Descansar hace que solo tú omitas el próximo juego. Los demás conservan su orden. Después de omitir un juego, recibes prioridad para el siguiente.','Leave removes only you':'Salir solo te elimina a ti','Leave removes only your name from the current game or waitlist. Other players remain in order, and you can join again later.':'Salir elimina solamente tu nombre del juego actual o de la lista. Los demás conservan su orden y puedes volver a unirte después.'
};

const zh:TranslationMap={
  'Log out':'退出登录','Log out?':'退出登录？','Enable alerts':'开启通知','Your actions':'你的操作','Next game':'下一场','Sit out':'轮休','Leave':'离开','Remove':'移除','Past games':'历史场次','Waitlist':'等候名单','No one waiting':'暂无等候者','Players will appear here.':'球员将在这里显示。','Live':'进行中','Group Up':'组队','Projected:':'预计：','You':'你','Add player':'添加球员','History':'记录','Members':'会员','Undo':'撤销','Redo':'重做','Reset waitlist':'重置等候名单','Regular waitlist':'普通等候名单','Rejoin waitlist':'重新加入名单','Teams mode':'球队模式','Rejoin requests':'重新加入请求','Set facility location':'设置场馆位置','Update facility location':'更新场馆位置','Restricted Members':'受限会员','Back to waitlist':'返回等候名单','Go back':'返回','Continue as guest':'以访客身份继续','Sign in':'登录','Create account':'创建账户','Admin':'管理员','Join waitlist':'加入等候名单','First name':'名字','Last initial or name':'姓氏首字母或全名','optional':'可选','What should we call you?':'怎么称呼你？','PLAYER DETAILS':'球员信息','Your name is added to the waitlist as soon as you continue.':'继续后，你的名字会立即加入等候名单。','I acknowledge':'我已了解','BEFORE YOU START':'开始之前','QUICK TOUR':'快速教程','Skip tutorial':'跳过教程','Back':'上一步','Next':'下一步','Finish':'完成','Your controls':'你的操作按钮','Who is playing now':'当前上场球员','Your place in line':'你的排队位置','Groups and past games':'组队与历史场次','Cancel':'取消','OK':'确定','Done':'完成','Game history':'比赛记录','No completed games yet.':'还没有已完成的比赛。','Notifications are on':'通知已开启','ADMIN ACCESS':'管理员登录','Manage OpenGym':'管理 OpenGym','Password':'密码','Username':'用户名','Email address':'电子邮箱','Welcome back':'欢迎回来','Create your OpenGym account':'创建 OpenGym 账户','Email me a sign-in link':'发送登录链接','ACCOUNT SIGN IN':'账户登录','CREATE ACCOUNT':'创建账户','Rejoin':'重新加入','Do you want to rejoin?':'你要重新加入吗？','REJOIN WAITLIST':'重新加入等候名单','Quick tour':'快速教程','Sit Out skips one game. Leave removes you. When you are playing, Next Game appears here.':'轮休会跳过一场；离开会将你移出名单。上场时，这里会显示“下一场”。','The players in this card are in the current game. Only they—and admins—can start the next game.':'此卡片中的球员正在上场。只有他们和管理员可以开始下一场。','Your number is your queue position. When you are waiting, your projected game appears beside your name.':'号码表示你的排队位置。等候时，预计场次会显示在名字旁。','Use Group Up beside another player to play together. Past Games shows who has already played.':'点击其他球员旁的“组队”即可一起上场。“历史场次”会显示已上场的球员。','This will remove you from the waitlist and sign you out.':'这会将你移出等候名单并退出登录。','Next Game affects everyone':'“下一场”会影响所有人','This button appears only when you are in the current game. Pressing it ends that game, advances the entire queue, and notifies every player—so use it only when the game is truly over.':'此按钮仅在你处于当前比赛时显示。点击后会结束当前比赛、推进整个队列并通知所有球员，因此请只在比赛确实结束时使用。','Sit Out affects only you':'“轮休”只影响你','Sit Out makes only you skip the next game. Everyone else keeps their order. After skipping one game, you receive priority for the following game.':'轮休只会让你跳过下一场。其他人的顺序不变。跳过一场后，你会在再下一场获得优先权。','Leave removes only you':'“离开”只会移除你','Leave removes only your name from the current game or waitlist. Other players remain in order, and you can join again later.':'离开只会将你的名字从当前比赛或等候名单中移除。其他球员顺序不变，你之后可以重新加入。'
};

Object.assign(es,{
  'LIVE QUEUE · ADMIN':'COLA EN VIVO · ADMINISTRADOR','LIVE QUEUE · HOST':'COLA EN VIVO · ANFITRIÓN','LIVE QUEUE · PLAYER':'COLA EN VIVO · JUGADOR',
  'Host Actions':'Acciones del anfitrión','Create Group':'Crear grupo','Cancel Grouping':'Cancelar agrupación','Substitute':'Sustituir','Cancel substitute':'Cancelar sustitución',
  'Undo and redo':'Deshacer y rehacer','Undo last session action':'Deshacer la última acción','Redo last undone session action':'Rehacer la última acción deshecha',
  'Permissions':'Permisos','Leave group':'Salir del grupo','Leave Group':'Salir del grupo','Edit player name':'Editar nombre del jugador',
  '(Host)':'(Anfitrión)','(restricted)':'(restringido)','(Sit-out priority)':'(Prioridad por descanso)','Only available when in a current game':'Solo disponible cuando estás en el juego actual',
  'Queue positions update live on every connected phone.':'Las posiciones se actualizan en vivo en todos los teléfonos conectados.',
  'Add a player':'Agregar un jugador','Add a walk-in player directly to the live queue. They do not need an account.':'Agrega directamente a la cola a un jugador que llegó sin cuenta.',
  'Add to waitlist':'Agregar a la lista','Adding…':'Agregando…','Optional: Last initial or name':'Opcional: inicial o apellido','Last name':'Apellido',
  'Looking for something?':'¿Buscas algo?','Search waitlist history':'Buscar en el historial','Waitlist history':'Historial de la lista','No waitlist activity yet.':'Aún no hay actividad en la lista.',
  'Action History':'Historial de acciones','Your history':'Tu historial','You have no host actions yet.':'Aún no tienes acciones como anfitrión.','You have no join or leave activity yet.':'Aún no tienes actividad de entrada o salida.',
  'No players are waiting to rejoin.':'Ningún jugador espera reingresar.','No accounts have been created yet.':'Aún no se han creado cuentas.','Verified account':'Cuenta verificada',
  'Facility location disabled':'Ubicación del centro desactivada','Players can join without an on-site location check.':'Los jugadores pueden unirse sin verificar su ubicación.',
  'Change language':'Cambiar idioma','Switch to light mode':'Cambiar a modo claro','Switch to dark mode':'Cambiar a modo oscuro',
  'Start the next game?':'¿Iniciar el siguiente juego?','This will notify all players and advance the entire queue to the next game.':'Esto notificará a todos y avanzará toda la cola al siguiente juego.',
  'Reset the entire waitlist?':'¿Reiniciar toda la lista?','This removes every player and clears past games. The admin can undo this action.':'Esto elimina a todos los jugadores y borra los juegos anteriores. El administrador puede deshacerlo.',
  'Continue':'Continuar','Accept':'Aceptar','Decline':'Rechazar','Send request':'Enviar solicitud','Group request':'Solicitud de grupo','Group update':'Actualización del grupo',
  'Permanent substitute request':'Solicitud de sustitución permanente','Substitute request sent':'Solicitud de sustitución enviada','Group request sent':'Solicitud de grupo enviada',
  'We’ll email you a secure link—no password needed.':'Te enviaremos un enlace seguro por correo; no necesitas contraseña.','Sending…':'Enviando…','The link expires for your security.':'El enlace caduca por tu seguridad.',
  'VOLLEYBALL WAITLIST':'LISTA DE ESPERA DE VOLEIBOL','Join the live volleyball queue from your phone.':'Únete a la cola de voleibol en vivo desde tu teléfono.',
  'Use Group Up beside another player when you want to play together.':'Usa Agruparse junto a otro jugador cuando quieran jugar juntos.',
  'Add Player':'Agregar jugador','Use Add Player to check in someone who does not have their phone.':'Usa Agregar jugador para registrar a alguien que no tiene su teléfono.',
  'Rejoin Requests':'Solicitudes de reingreso','Use Create Group to select players who want to play together.':'Usa Crear grupo para seleccionar jugadores que quieren jugar juntos.',
  'Use Substitute to select two players and permanently swap their positions.':'Usa Sustituir para seleccionar dos jugadores e intercambiar permanentemente sus posiciones.',
  'Sit Out and Remove':'Descansar y eliminar','Use Sit Out beside a player to skip only that player for one game. Use Remove to take that player off the waitlist.':'Usa Descansar para que solo ese jugador omita un juego. Usa Eliminar para quitarlo de la lista.',
  'History shows when players joined, left, sat out, grouped, substituted, or changed games during this waitlist.':'El historial muestra cuándo los jugadores entraron, salieron, descansaron, se agruparon, sustituyeron o cambiaron de juego.',
  'Select up to 6 players to become a group.':'Selecciona hasta 6 jugadores para formar un grupo.','Choose 2 players to swap positions.':'Elige 2 jugadores para intercambiar posiciones.'
});

Object.assign(zh,{
  'LIVE QUEUE · ADMIN':'实时队列 · 管理员','LIVE QUEUE · HOST':'实时队列 · 主持人','LIVE QUEUE · PLAYER':'实时队列 · 球员',
  'Host Actions':'主持人操作','Create Group':'创建小组','Cancel Grouping':'取消组队','Substitute':'替换','Cancel substitute':'取消替换',
  'Undo and redo':'撤销与重做','Undo last session action':'撤销上一个操作','Redo last undone session action':'重做上一个撤销的操作',
  'Permissions':'权限','Leave group':'退出小组','Leave Group':'退出小组','Edit player name':'编辑球员姓名',
  '(Host)':'（主持人）','(restricted)':'（受限）','(Sit-out priority)':'（轮休优先）','Only available when in a current game':'仅在当前比赛中可用',
  'Queue positions update live on every connected phone.':'队列位置会在所有已连接的手机上实时更新。',
  'Add a player':'添加球员','Add a walk-in player directly to the live queue. They do not need an account.':'将现场球员直接加入实时队列，无需账户。',
  'Add to waitlist':'加入等候名单','Adding…':'正在添加…','Optional: Last initial or name':'可选：姓氏首字母或全名','Last name':'姓氏',
  'Looking for something?':'想查找什么？','Search waitlist history':'搜索等候名单记录','Waitlist history':'等候名单记录','No waitlist activity yet.':'暂无等候名单活动。',
  'Action History':'操作记录','Your history':'你的记录','You have no host actions yet.':'你还没有主持人操作记录。','You have no join or leave activity yet.':'你还没有加入或离开记录。',
  'No players are waiting to rejoin.':'没有球员等待重新加入。','No accounts have been created yet.':'尚未创建账户。','Verified account':'已验证账户',
  'Facility location disabled':'场馆位置已停用','Players can join without an on-site location check.':'球员无需现场位置检查即可加入。',
  'Change language':'更改语言','Switch to light mode':'切换到浅色模式','Switch to dark mode':'切换到深色模式',
  'Start the next game?':'开始下一场比赛？','This will notify all players and advance the entire queue to the next game.':'这会通知所有球员并将整个队列推进到下一场。',
  'Reset the entire waitlist?':'重置整个等候名单？','This removes every player and clears past games. The admin can undo this action.':'这会移除所有球员并清除历史比赛。管理员可以撤销此操作。',
  'Continue':'继续','Accept':'接受','Decline':'拒绝','Send request':'发送请求','Group request':'组队请求','Group update':'小组更新',
  'Permanent substitute request':'永久替换请求','Substitute request sent':'替换请求已发送','Group request sent':'组队请求已发送',
  'We’ll email you a secure link—no password needed.':'我们会发送安全登录链接，无需密码。','Sending…':'正在发送…','The link expires for your security.':'为保障安全，该链接会过期。',
  'VOLLEYBALL WAITLIST':'排球等候名单','Join the live volleyball queue from your phone.':'使用手机加入实时排球队列。',
  'Use Group Up beside another player when you want to play together.':'想一起比赛时，请使用另一名球员旁的“组队”。',
  'Add Player':'添加球员','Use Add Player to check in someone who does not have their phone.':'使用“添加球员”为没有手机的人登记。',
  'Rejoin Requests':'重新加入请求','Use Create Group to select players who want to play together.':'使用“创建小组”选择想一起比赛的球员。',
  'Use Substitute to select two players and permanently swap their positions.':'使用“替换”选择两名球员并永久交换位置。',
  'Sit Out and Remove':'轮休与移除','Use Sit Out beside a player to skip only that player for one game. Use Remove to take that player off the waitlist.':'使用球员旁的“轮休”让该球员跳过一场。使用“移除”将其移出等候名单。',
  'History shows when players joined, left, sat out, grouped, substituted, or changed games during this waitlist.':'记录会显示球员在本次等候名单中加入、离开、轮休、组队、替换或更换比赛的时间。',
  'Select up to 6 players to become a group.':'最多选择 6 名球员组成小组。','Choose 2 players to swap positions.':'选择 2 名球员交换位置。'
});

function translateDynamic(value:string,language:AppLanguage){
  if(language==='en')return value;
  const game=value.match(/^Game (\d+)$/);if(game)return language==='es'?`Juego ${game[1]}`:`第 ${game[1]} 场`;
  const playing=value.match(/^(\d+) playing$/);if(playing)return language==='es'?`${playing[1]} jugando`:`${playing[1]} 人上场`;
  const waiting=value.match(/^(\d+) waiting$/);if(waiting)return language==='es'?`${waiting[1]} esperando`:`${waiting[1]} 人等候`;
  const projected=value.match(/^Projected: Game (\d+)$/);if(projected)return language==='es'?`Proyección: Juego ${projected[1]}`:`预计：第 ${projected[1]} 场`;
  const tour=value.match(/^QUICK TOUR · (\d+) OF (\d+)$/);if(tour)return language==='es'?`RECORRIDO RÁPIDO · ${tour[1]} DE ${tour[2]}`:`快速教程 · ${tour[1]}/${tour[2]}`;
  const rejoin=value.match(/^Rejoin requests \((\d+)\)$/);if(rejoin)return language==='es'?`Solicitudes de reingreso (${rejoin[1]})`:`重新加入请求（${rejoin[1]}）`;
  if(value.startsWith('This is a ')&&value.endsWith(' waitlist')){const mode=value.slice(10,-9);return language==='es'?`Esta es una lista ${mode==='REJOIN'?'de REINGRESO':'REGULAR'}`:`这是${mode==='REJOIN'?'重新加入':'普通'}等候名单`;}
  return value;
}

export function translateUiText(value:string,language:AppLanguage){
  const clean=value.trim();if(!clean||language==='en')return value;
  const translated=(language==='es'?es:zh)[clean]??translateDynamic(clean,language);
  if(translated===clean)return value;
  const leading=value.match(/^\s*/)?.[0]??'';const trailing=value.match(/\s*$/)?.[0]??'';
  return `${leading}${translated}${trailing}`;
}
