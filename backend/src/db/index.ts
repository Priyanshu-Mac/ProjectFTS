import * as mem from './memory';

let generateFileNo = mem.generateFileNo as any;
let createFile = mem.createFile as any;
let listFiles = mem.listFiles as any;
let getFile = mem.getFile as any;
let addEvent = mem.addEvent as any;
let listEvents = mem.listEvents as any;
let computeSlaStatus = (mem as any).computeSlaStatus as any;
let refreshFileSla = async (_id: number) => false as any;
let createUser = (mem as any).createUser as any;
let findUserByUsername = (mem as any).findUserByUsername as any;

if (process.env.DATABASE_URL) {
  try {
    // lazy load pg adapter
    // eslint-disable-next-line @typescript-eslint/no-var-requires
    const pg = require('./pg');
    generateFileNo = pg.generateFileNo;
    createFile = pg.createFile;
    listFiles = pg.listFiles;
    getFile = pg.getFile;
    addEvent = pg.addEvent;
    listEvents = pg.listEvents;
  computeSlaStatus = pg.computeSlaStatus;
    refreshFileSla = pg.refreshFileSla;
    createUser = pg.createUser;
    findUserByUsername = pg.findUserByUsername;
  } catch (e: any) {
    // fall back to memory and log the error to help debugging
    // eslint-disable-next-line no-console
    console.error('[db] pg adapter load failed:', e && e.stack ? e.stack : e);
  }
}

export { generateFileNo, createFile, listFiles, getFile, addEvent, listEvents, computeSlaStatus, createUser, findUserByUsername, refreshFileSla };

// Log which adapter is in use (do not print connection string)
try {
  const usingPg = (process.env.DATABASE_URL && listFiles !== mem.listFiles);
  // eslint-disable-next-line no-console
  console.log(`[db] adapter=${usingPg ? 'pg' : 'memory'} usingEnv=${!!process.env.DATABASE_URL}`);
} catch (err) {
  // ignore logging errors
}
