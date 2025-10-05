import React from 'react';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { userService } from '../services/userService';
import { fileService } from '../services/fileService';
import { useNavigate } from 'react-router-dom';
import toast from 'react-hot-toast';

type Role = 'Clerk'|'AccountsOfficer'|'COF'|'Admin';

const AdminDashboardPage: React.FC = () => {
  const navigate = useNavigate();
  const qc = useQueryClient();
  const [q, setQ] = React.useState('');
  const [createOpen, setCreateOpen] = React.useState(false);
  const [editUser, setEditUser] = React.useState<any|null>(null);

  const { data: usersResp, isLoading } = useQuery({
    queryKey: ['users', q],
    queryFn: async () => userService.list({ q, limit: 100 }),
  });

  const users = usersResp?.results ?? [];

  function RoleBadge({ role }: { role: string }) {
    const color = role === 'Admin' ? 'bg-purple-100 text-purple-800' : role === 'COF' ? 'bg-blue-100 text-blue-800' : role === 'AccountsOfficer' ? 'bg-green-100 text-green-800' : 'bg-gray-100 text-gray-800';
    return <span className={`px-2 py-0.5 rounded text-xs ${color}`}>{role}</span>;
  }

  return (
    <div className="space-y-6">
      <div className="border-b border-gray-200 pb-4 flex items-center justify-between">
        <div>
          <h1 className="text-2xl font-bold text-gray-900">Admin Dashboard</h1>
          <p className="mt-1 text-sm text-gray-600">Full control: manage users and handle any file</p>
        </div>
        <div className="flex items-center gap-3">
          <input className="border rounded px-3 py-2 text-sm" placeholder="Search users" value={q} onChange={(e)=>setQ(e.target.value)} />
          <button className="btn btn-primary" onClick={()=>setCreateOpen(true)}>New User</button>
        </div>
      </div>

      {/* Quick File Controls */}
      <div className="grid grid-cols-1 md:grid-cols-2 gap-6">
        <div className="card">
          <div className="card-header"><h3 className="text-lg font-medium">Find & Open Any File</h3><p className="text-sm text-gray-500">Search and open in File Search</p></div>
          <div className="card-body">
            <QuickFileOpener onOpen={(id)=>navigate('/file-search', { state: { openId: id } })} />
          </div>
        </div>
        <div className="card">
          <div className="card-header"><h3 className="text-lg font-medium">Move Any File</h3><p className="text-sm text-gray-500">Go to Move File page</p></div>
          <div className="card-body">
            <button className="btn btn-secondary" onClick={()=>navigate('/move-file')}>Open Move File</button>
          </div>
        </div>
      </div>

      {/* Users Table */}
      <div className="card">
        <div className="card-header">
          <h3 className="text-lg font-medium">Users</h3>
          <span className="text-sm text-gray-500">({usersResp?.total ?? users.length})</span>
        </div>
        <div className="card-body">
          {isLoading ? (<div>Loading…</div>) : (
            <div className="overflow-x-auto">
              <table className="table">
                <thead className="table-header">
                  <tr>
                    <th>ID</th>
                    <th>Username</th>
                    <th>Name</th>
                    <th>Role</th>
                    <th>Office</th>
                    <th>Email</th>
                    <th>Actions</th>
                  </tr>
                </thead>
                <tbody className="table-body">
                  {(users || []).map((u: any) => (
                    <tr key={u.id}>
                      <td>{u.id}</td>
                      <td>{u.username}</td>
                      <td>{u.name}</td>
                      <td><RoleBadge role={u.role} /></td>
                      <td>{u.office_id ?? '—'}</td>
                      <td>{u.email ?? '—'}</td>
                      <td className="space-x-2">
                        <button className="btn btn-xs" onClick={()=>setEditUser(u)}>Edit</button>
                        <button className="btn btn-xs btn-danger" onClick={async ()=>{
                          const pw = prompt('New password for '+u.username+':');
                          if (!pw) return;
                          await userService.resetPassword(u.id, pw);
                          toast.success('Password reset');
                        }}>Reset Password</button>
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}
        </div>
      </div>

      {createOpen && (
        <UserModal
          title="Create User"
          onClose={()=>setCreateOpen(false)}
          onSubmit={async (payload)=>{
            await userService.create(payload as any);
            toast.success('User created');
            setCreateOpen(false);
            qc.invalidateQueries({ queryKey: ['users'] });
          }}
        />
      )}

      {editUser && (
        <UserModal
          title="Edit User"
          user={editUser}
          onClose={()=>setEditUser(null)}
          onSubmit={async (payload)=>{
            const { password, ...rest } = payload as any;
            await userService.update(editUser.id, rest);
            toast.success('User updated');
            setEditUser(null);
            qc.invalidateQueries({ queryKey: ['users'] });
          }}
        />
      )}
    </div>
  );
};

const QuickFileOpener: React.FC<{ onOpen: (id: number)=>void }> = ({ onOpen }) => {
  const [q, setQ] = React.useState('');
  const { data, isLoading, refetch } = useQuery({
    queryKey: ['admin-quick-file', q],
    queryFn: async () => {
      const res = await fileService.listFiles({ q, limit: 10, includeSla: false });
      return res?.results ?? [];
    }
  });
  return (
    <div className="space-y-2">
      <input className="w-full border rounded px-3 py-2" placeholder="Search by file no. or subject" value={q} onChange={(e)=>{ setQ(e.target.value); const t = setTimeout(()=>refetch(), 200); return ()=>clearTimeout(t as any); }} />
      {isLoading ? (<div className="text-sm text-gray-500">Searching…</div>) : (
        <div className="space-y-1">
          {(data || []).map((f: any)=> (
            <button key={f.id} className="w-full text-left px-3 py-2 rounded border hover:bg-gray-50" onClick={()=>onOpen(Number(f.id))}>
              <div className="flex items-center justify-between">
                <div>
                  <div className="font-medium">{f.file_no}</div>
                  <div className="text-xs text-gray-500 truncate max-w-[40rem]">{f.subject}</div>
                </div>
                <div className="text-xs text-gray-600">#{f.id}</div>
              </div>
            </button>
          ))}
        </div>
      )}
    </div>
  );
};

const UserModal: React.FC<{ title: string; user?: any|null; onClose: ()=>void; onSubmit: (payload: { username: string; name: string; role: Role; password?: string; office_id?: number; email?: string })=>Promise<void> }> = ({ title, user, onClose, onSubmit }) => {
  const [username, setUsername] = React.useState(user?.username || '');
  const [name, setName] = React.useState(user?.name || '');
  const [role, setRole] = React.useState<Role>((user?.role || 'Clerk') as Role);
  const [email, setEmail] = React.useState(user?.email || '');
  const [officeId, setOfficeId] = React.useState<number | ''>(user?.office_id ?? '');
  const [password, setPassword] = React.useState('');
  const isEdit = !!user;
  return (
    <div className="fixed inset-0 bg-black/40 flex items-center justify-center z-50">
      <div className="bg-white rounded-lg shadow-lg w-full max-w-lg">
        <div className="px-4 py-3 border-b flex items-center justify-between">
          <h3 className="text-lg font-medium">{title}</h3>
          <button className="text-gray-500 hover:text-gray-700" onClick={onClose}>✕</button>
        </div>
        <div className="p-4 space-y-3">
          <div className="grid grid-cols-2 gap-3">
            <div>
              <label className="text-xs text-gray-600">Username</label>
              <input className="w-full border rounded px-3 py-2" value={username} disabled={isEdit} onChange={(e)=>setUsername(e.target.value)} />
            </div>
            <div>
              <label className="text-xs text-gray-600">Name</label>
              <input className="w-full border rounded px-3 py-2" value={name} onChange={(e)=>setName(e.target.value)} />
            </div>
            <div>
              <label className="text-xs text-gray-600">Role</label>
              <select className="w-full border rounded px-3 py-2" value={role} onChange={(e)=>setRole(e.target.value as Role)}>
                <option>Clerk</option>
                <option>AccountsOfficer</option>
                <option>COF</option>
                <option>Admin</option>
              </select>
            </div>
            <div>
              <label className="text-xs text-gray-600">Office ID</label>
              <input className="w-full border rounded px-3 py-2" value={officeId} onChange={(e)=>setOfficeId(e.target.value ? Number(e.target.value) : '')} />
            </div>
            <div className="col-span-2">
              <label className="text-xs text-gray-600">Email</label>
              <input type="email" className="w-full border rounded px-3 py-2" value={email} onChange={(e)=>setEmail(e.target.value)} />
            </div>
            {!isEdit && (
              <div className="col-span-2">
                <label className="text-xs text-gray-600">Password</label>
                <input type="password" className="w-full border rounded px-3 py-2" value={password} onChange={(e)=>setPassword(e.target.value)} />
              </div>
            )}
          </div>
        </div>
        <div className="px-4 py-3 border-t flex items-center justify-end gap-3">
          <button className="btn" onClick={onClose}>Cancel</button>
          <button className="btn btn-primary" onClick={async ()=>{
            const payload: any = { username, name, role, email: email || undefined };
            if (officeId !== '') payload.office_id = Number(officeId);
            if (!isEdit) payload.password = password;
            if (isEdit) delete payload.username;
            await onSubmit(payload);
          }}>{isEdit ? 'Save' : 'Create'}</button>
        </div>
      </div>
    </div>
  );
};

export default AdminDashboardPage;
