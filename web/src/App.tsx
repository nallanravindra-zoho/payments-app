import type { ReactNode } from 'react';
import { Navigate, Route, Routes } from 'react-router-dom';
import { Shell } from './Shell';
import { Loading } from './components/ui';
import { getToken, homeFor, useApp, type Role } from './lib/session';
import { Login, ResetPassword, RoleScreen, StudentActivate } from './screens/auth';
import { AddStudent, Assign, FeePlan, Import, InvoicePreview, Invite, Profile } from './screens/onboarding';
import { Allocate, BatchDetail, Batches, Cash, Exports, Home, Inbox, Issue, NewBatch, PromiseToPay, Receipt, Settings, StudentProfile, Target, Verify } from './screens/owner';
import { CalendarScreen, ParentSchedule, StudentSchedule, TeacherCalendar } from './screens/schedule';
import { Family, FeeUrl, Methods, ParentHistory, ParentHome, Proof, StillPending, Success, UpiPending } from './screens/parent';
import { StudentAttendance, StudentClass, StudentFees, StudentHome, StudentProfileScreen } from './screens/student';
import { Attendance, Makeup, TeacherHome } from './screens/teacher';
import { Aging, Gst, Profit, Reconcile, Retention, Revenue } from './screens/reports';

/** Route guard. Roles come from the server (my_context); the client only routes, it never grants access. */
function Gate({ roles, token, noInst, children }: { roles?: Role[]; token?: boolean; noInst?: boolean; children: ReactNode }) {
  const { ready, session, sel } = useApp();
  if (!ready) return <Loading />;
  if (token && getToken() && sel.role !== 'admin' && sel.role !== 'teacher') return <>{children}</>;
  if (!session) return <Navigate to="/login" replace />;
  if (!sel.role) return <Navigate to="/role" replace />;
  if (roles && !roles.includes(sel.role)) return <Navigate to={homeFor(sel.role)} replace />;
  if ((sel.role === 'admin' || sel.role === 'teacher') && !sel.instId && !noInst) return <Navigate to="/role" replace />;
  if ((sel.role === 'parent') && !sel.familyId) return <Navigate to="/role" replace />;
  if ((sel.role === 'student') && !sel.studentId) return <Navigate to="/role" replace />;
  return <>{children}</>;
}
const A = (el: ReactNode) => <Gate roles={['admin']}>{el}</Gate>;
const P = (el: ReactNode) => <Gate roles={['parent', 'student']} token>{el}</Gate>;
const S = (el: ReactNode) => <Gate roles={['student']}>{el}</Gate>;
const T = (el: ReactNode) => <Gate roles={['teacher']}>{el}</Gate>;
const AT = (el: ReactNode) => <Gate roles={['admin', 'teacher']}>{el}</Gate>;
const Pub = (el: ReactNode) => <>{el}</>;

function Root() {
  const { ready, session, sel } = useApp();
  if (!ready) return <Loading />;
  if (!session) return <Navigate to={getToken() ? '/family' : '/login'} replace />;
  return <Navigate to={homeFor(sel.role)} replace />;
}

export function App() {
  return (
    <div className="app">
      <Shell>
        <Routes>
          <Route path="/" element={<Root />} />
          {/* onboarding & identity */}
          <Route path="/login" element={Pub(<Login />)} />
          <Route path="/signup" element={<Navigate to="/login" replace />} />
          <Route path="/otp" element={<Navigate to="/login" replace />} />
          <Route path="/reset" element={<ResetPassword />} />
          <Route path="/role" element={<RoleScreen />} />
          <Route path="/studentactivate" element={<StudentActivate />} />
          <Route path="/profile" element={<Gate roles={['admin']} noInst><Profile /></Gate>} />
          <Route path="/import" element={A(<Import />)} />
          <Route path="/addstudent" element={A(<AddStudent />)} />
          <Route path="/assign" element={A(<Assign />)} />
          <Route path="/feeplan" element={A(<FeePlan />)} />
          <Route path="/invoice" element={A(<InvoicePreview />)} />
          <Route path="/invite" element={A(<Invite />)} />
          {/* owner */}
          <Route path="/home" element={A(<Home />)} />
          <Route path="/calendar" element={A(<CalendarScreen />)} />
          <Route path="/batches" element={A(<Batches />)} />
          <Route path="/newbatch" element={A(<NewBatch />)} />
          <Route path="/batchdetail/:id" element={A(<BatchDetail />)} />
          <Route path="/student/:id?" element={A(<StudentProfile />)} />
          <Route path="/money" element={A(<Inbox />)} />
          <Route path="/inbox" element={A(<Inbox />)} />
          <Route path="/verify/:id" element={A(<Verify />)} />
          <Route path="/issue/:id" element={A(<Issue />)} />
          <Route path="/allocate/:id?" element={A(<Allocate />)} />
          <Route path="/cash/:id?" element={A(<Cash />)} />
          <Route path="/settings" element={A(<Settings />)} />
          <Route path="/target" element={A(<Target />)} />
          <Route path="/exports" element={A(<Exports />)} />
          <Route path="/revenue" element={A(<Revenue />)} />
          <Route path="/business" element={A(<Revenue />)} />
          <Route path="/aging" element={A(<Aging />)} />
          <Route path="/profit" element={A(<Profit />)} />
          <Route path="/reconcile" element={A(<Reconcile />)} />
          <Route path="/gst" element={A(<Gst />)} />
          <Route path="/retention" element={A(<Retention />)} />
          <Route path="/promise/:id?" element={<Gate roles={['admin', 'parent', 'student']} token><PromiseToPay /></Gate>} />
          <Route path="/receipt/:id" element={<Gate token><Receipt /></Gate>} />
          {/* parent / no-install link / adult student checkout */}
          <Route path="/pay/:token" element={Pub(<FeeUrl />)} />
          <Route path="/feeurl" element={A(<FeeUrl />)} />
          <Route path="/parenthome" element={<Gate roles={['parent']}><ParentHome /></Gate>} />
          <Route path="/family" element={P(<Family />)} />
          <Route path="/methods" element={P(<Methods />)} />
          <Route path="/checkout" element={<Navigate to="/methods" replace />} />
          <Route path="/upipending/:id" element={P(<UpiPending />)} />
          <Route path="/proof" element={P(<Proof />)} />
          <Route path="/success/:id" element={P(<Success />)} />
          <Route path="/stillpending/:id?" element={P(<StillPending />)} />
          <Route path="/parenthistory" element={P(<ParentHistory />)} />
          <Route path="/parentschedule" element={<Gate roles={['parent']}><ParentSchedule /></Gate>} />
          {/* teacher */}
          <Route path="/teacherhome" element={T(<TeacherHome />)} />
          <Route path="/teachercalendar" element={T(<TeacherCalendar />)} />
          <Route path="/attendance/:id?" element={AT(<Attendance />)} />
          <Route path="/makeup" element={AT(<Makeup />)} />
          {/* student */}
          <Route path="/studenthome" element={S(<StudentHome />)} />
          <Route path="/studentschedule" element={S(<StudentSchedule />)} />
          <Route path="/studentclass/:id?" element={S(<StudentClass />)} />
          <Route path="/studentattendance/:id?" element={S(<StudentAttendance />)} />
          <Route path="/studentprofile" element={S(<StudentProfileScreen />)} />
          <Route path="/studentfees" element={S(<StudentFees />)} />
          <Route path="*" element={<Navigate to="/" replace />} />
        </Routes>
      </Shell>
    </div>
  );
}
