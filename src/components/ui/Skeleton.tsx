import { cn } from '@/lib/utils'

export function Skeleton({ className }: { className?: string }) {
  return (
    <div
      className={cn(
        'shimmer overflow-hidden rounded-2xl bg-elevated',
        className,
      )}
      aria-hidden="true"
    />
  )
}

export function PageSkeleton() {
  return (
    <div className="page-x mx-auto w-full max-w-5xl py-6">
      <div className="flex items-center justify-between">
        <div className="space-y-2">
          <Skeleton className="h-3.5 w-24 rounded-full" />
          <Skeleton className="h-7 w-44" />
        </div>
        <Skeleton className="h-11 w-11 rounded-2xl" />
      </div>
      <Skeleton className="mt-6 h-56 w-full rounded-[28px]" />
      <div className="mt-4 grid grid-cols-2 gap-3">
        <Skeleton className="h-24 rounded-3xl" />
        <Skeleton className="h-24 rounded-3xl" />
      </div>
      <Skeleton className="mt-4 h-44 w-full rounded-3xl" />
    </div>
  )
}
