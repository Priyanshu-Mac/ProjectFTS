import * as mem from './memory';

let generateFileNo = mem.generateFileNo as any;
let createFile = mem.createFile as any;
let listFiles = mem.listFiles as any;
let getFile = mem.getFile as any;
let addEvent = mem.addEvent as any;
let listEvents = mem.listEvents as any;
let listAllEvents = (mem as any).listAllEvents as any;
let computeSlaStatus = (mem as any).computeSlaStatus as any;
let refreshFileSla = async (_id: number) => false as any;
let updateFileDraft = (mem as any).updateFileDraft as any;
let createUser = (mem as any).createUser as any;
let listUsers = (mem as any).listUsers as any;
let updateUser = (mem as any).updateUser as any;
let findUserByUsername = (mem as any).findUserByUsername as any;
let getUserById = (mem as any).getUserById as any;
let updateUserPassword = (mem as any).updateUserPassword as any;
let addAuditLog = async (_entry: any) => true as any;
let listAuditLogs = (mem as any).listAuditLogs as any;
// Share token helpers: default no-op fallbacks for memory adapter
let setFileShareToken = async (_file_id: number, _token: string, _created_by?: number|null) => true as any;
let isValidFileShareToken = async (_file_id: number, _token: string) => true as any;
let getShareToken = async (_file_id: number) => null as any;
let getOrCreateShareToken = async (_file_id: number, _created_by?: number|null, _force?: boolean) => '' as any;
let findFileIdByToken = async (_token: string) => null as any;

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
  listAllEvents = pg.listAllEvents;
  computeSlaStatus = pg.computeSlaStatus;
    refreshFileSla = pg.refreshFileSla;
    createUser = pg.createUser;
  listUsers = pg.listUsers;
  updateUser = pg.updateUser;
    findUserByUsername = pg.findUserByUsername;
    getUserById = pg.getUserById;
  updateUserPassword = pg.updateUserPassword;
    addAuditLog = pg.addAuditLog;
  listAuditLogs = pg.listAuditLogs;
    // Wire share token helpers when pg adapter is active
    setFileShareToken = pg.setFileShareToken;
    isValidFileShareToken = pg.isValidFileShareToken;
    getShareToken = pg.getShareToken;
    getOrCreateShareToken = pg.getOrCreateShareToken;
    findFileIdByToken = pg.findFileIdByToken;
  } catch (e: any) {
    // fall back to memory and log the error to help debugging
    // eslint-disable-next-line no-console
    console.error('[db] pg adapter load failed:', e && e.stack ? e.stack : e);
  }
}

export { generateFileNo, createFile, listFiles, getFile, addEvent, listEvents, listAllEvents, computeSlaStatus, createUser, listUsers, updateUser, findUserByUsername, getUserById, updateUserPassword, refreshFileSla, addAuditLog, listAuditLogs, setFileShareToken, isValidFileShareToken, getShareToken, getOrCreateShareToken, findFileIdByToken };

// Log which adapter is in use (do not print connection string)
try {
  const usingPg = (process.env.DATABASE_URL && listFiles !== mem.listFiles);
  // eslint-disable-next-line no-console
  console.log(`[db] adapter=${usingPg ? 'pg' : 'memory'} usingEnv=${!!process.env.DATABASE_URL}`);
} catch (err) {
  // ignore logging errors
}
