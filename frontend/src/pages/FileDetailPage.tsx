import React, { useEffect, useState } from 'react';
import { useParams, useSearchParams } from 'react-router-dom';
import { useNavigate } from 'react-router-dom';
import { fileService } from '../services/fileService';
import { authService } from '../services/authService';
import toast from 'react-hot-toast';

export default function FileDetailPage() {
  const { id } = useParams();
  const [search] = useSearchParams();
  const token = search.get('t');
  const [file, setFile] = useState<any>(null);
  const [loading, setLoading] = useState(false);
  const navigate = useNavigate();

  useEffect(() => {
    async function load() {
      setLoading(true);
      try {
        // Require login before fetching any file data. If not logged in, redirect to login with return url
        if (!authService.isAuthenticated()) {
          // keep token in query string so it can be used after login
          const returnTo = window.location.pathname + window.location.search;
          navigate(`/login?next=${encodeURIComponent(returnTo)}`);
          setLoading(false);
          return;
        }

        if (token) {
          // authenticated fetch using token endpoint (server will also check token)
          const res = await fileService.getFileByToken(token);
          setFile(res);
        } else if (id) {
          const res = await fileService.getFile(Number(id));
          setFile(res);
        }
      } catch (e: any) {
        toast.error(String(e?.message ?? 'Failed to load file'));
      } finally {
        setLoading(false);
      }
    }
    load();
  }, [id, token]);

  if (loading) return <div className="p-6 bg-white border rounded">Loading file...</div>;
  if (!file) return <div className="p-6 bg-white border rounded">File not found or access denied.</div>;

  return (
    <div className="p-6 bg-white border rounded">
      <h2 className="text-xl font-bold mb-2">{file.file_no}</h2>
      <div className="text-sm text-gray-600 mb-4">Subject: {file.subject}</div>
      <dl className="grid grid-cols-2 gap-4">
        <div><dt className="font-semibold">Owning office</dt><dd>{file.owning_office?.name ?? file.owning_office}</dd></div>
        <div><dt className="font-semibold">Category</dt><dd>{file.category?.name ?? file.category}</dd></div>
        <div><dt className="font-semibold">Status</dt><dd>{file.status}</dd></div>
        <div><dt className="font-semibold">Created by</dt><dd>{file.created_by_user?.username ?? file.created_by}</dd></div>
      </dl>
    </div>
  );
}
