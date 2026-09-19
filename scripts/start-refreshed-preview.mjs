// Local preview only. The caller selects audited public generations; all
// existing private-owner files and saved research events retain their paths.
import path from 'node:path';
import {DatabaseSync} from 'node:sqlite';
const [runtime,warehouse,prices,portText='8794']=process.argv.slice(2);
const port=Number(portText);
if(![runtime,warehouse,prices].every(p=>p&&path.isAbsolute(p))||!Number.isInteger(port)||port<1024||port>65535||process.env.NODE_ENV==='production')throw Error('absolute local generation paths and a non-production port required');
const dbFile=path.resolve('output/owner-portfolio-20260912/portfolio-v4.sqlite');
const db=new DatabaseSync(dbFile,{readOnly:true});
const owner=db.prepare('SELECT owner_hash FROM snapshot WHERE id=1').get()?.owner_hash;db.close();
if(!owner)throw Error('existing_preview_owner_required');
Object.assign(process.env,{
  INVESTMENT_WORKFLOW_ENABLED:'true',API_AUTH_DEV_BYPASS:'true',
  INVESTMENT_DB_PATH:'output/investment-workflow-20260908/decisions.sqlite',
  SQLITE_DB_PATH:runtime,USER_PORTFOLIO_DATA_DIR:'output/investment-workflow-20260908/users',
  PORTFOLIO_NAV_AUTO_CAPTURE:'false',DIVIDEND_CALENDAR_AUTO_REFRESH:'false',
  GURU_BACKTEST_AUTO_REFRESH:'false',THIRTEEN_F_AUTO_REFRESH:'false',
  HEDGE_DB_PATH:'output/hedge-data-20260910/hedge.sqlite',
  STRATEGY_DATA_DB_PATH:warehouse,STRATEGY_COMPOSITION_PRICE_DB_PATH:prices,
  LOCAL_OWNER_PORTFOLIO_DB:dbFile,LOCAL_OWNER_PORTFOLIO_HASH:owner,PORT:String(port),
});
await import('../server/index.js');
