import { useEffect } from 'react'
import { Outlet, useLocation } from 'react-router-dom'
import { BottomNav } from './BottomNav'
import { SideNav } from './SideNav'

export function AppShell() {
  const location = useLocation()
  const immersive = location.pathname === '/scan'

  useEffect(() => {
    window.scrollTo({ top: 0, behavior: 'auto' })
  }, [location.pathname])

  if (immersive) {
    return <Outlet />
  }

  return (
    <div className="min-h-[100svh]">
      <SideNav />
      <div className="lg:pl-[268px]">
        <main className="mx-auto w-full max-w-[1080px] pb-nav lg:pb-14">
          <div key={location.pathname} className="animate-fade-in">
            <Outlet />
          </div>
        </main>
      </div>
      <BottomNav />
    </div>
  )
}
