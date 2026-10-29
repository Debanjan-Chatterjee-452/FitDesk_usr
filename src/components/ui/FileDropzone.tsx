import { useEffect, useRef, useState, type DragEvent } from 'react'
import { Camera, FileText, Image as ImageIcon, UploadCloud, X } from 'lucide-react'
import { cn } from '@/lib/utils'
import { Button } from './Button'

interface FileDropzoneProps {
  file: File | null
  onFile: (file: File | null) => void
  error?: string | null
  existingName?: string | null
  disabled?: boolean
}

function formatFileSize(bytes: number): string {
  if (bytes < 1024) return `${bytes} B`
  if (bytes < 1024 * 1024) return `${Math.round(bytes / 1024)} KB`
  return `${(bytes / (1024 * 1024)).toFixed(1)} MB`
}

export function FileDropzone({
  file,
  onFile,
  error,
  existingName,
  disabled,
}: FileDropzoneProps) {
  const inputRef = useRef<HTMLInputElement>(null)
  const cameraRef = useRef<HTMLInputElement>(null)
  const [dragging, setDragging] = useState(false)
  const [previewUrl, setPreviewUrl] = useState<string | null>(null)

  useEffect(() => {
    if (!file || !file.type.startsWith('image/')) {
      setPreviewUrl(null)
      return
    }
    const url = URL.createObjectURL(file)
    setPreviewUrl(url)
    return () => URL.revokeObjectURL(url)
  }, [file])

  const handleDrop = (event: DragEvent<HTMLDivElement>) => {
    event.preventDefault()
    setDragging(false)
    if (disabled) return
    const dropped = event.dataTransfer.files?.[0]
    if (dropped) onFile(dropped)
  }

  const isPdf = file?.type === 'application/pdf' || file?.name.toLowerCase().endsWith('.pdf')

  return (
    <div>
      <input
        ref={inputRef}
        type="file"
        accept="image/jpeg,image/png,image/webp,image/heic,image/heif,application/pdf"
        className="hidden"
        disabled={disabled}
        onChange={(event) => {
          const selected = event.target.files?.[0] ?? null
          if (selected) onFile(selected)
          event.target.value = ''
        }}
      />
      <input
        ref={cameraRef}
        type="file"
        accept="image/*"
        capture="environment"
        className="hidden"
        disabled={disabled}
        onChange={(event) => {
          const selected = event.target.files?.[0] ?? null
          if (selected) onFile(selected)
          event.target.value = ''
        }}
      />

      {file ? (
        <div className="rounded-3xl border border-primary/20 bg-primary-soft/35 p-4">
          <div className="flex items-center gap-3.5">
            <div className="flex h-14 w-14 shrink-0 items-center justify-center overflow-hidden rounded-2xl border border-primary/15 bg-surface">
              {previewUrl ? (
                <img src={previewUrl} alt="Document preview" className="h-full w-full object-cover" />
              ) : isPdf ? (
                <FileText className="h-6 w-6 text-danger" />
              ) : (
                <ImageIcon className="h-6 w-6 text-primary-strong" />
              )}
            </div>
            <div className="min-w-0 flex-1">
              <p className="truncate text-[13.5px] font-semibold text-ink">{file.name}</p>
              <p className="mt-0.5 text-[11.5px] text-muted">
                {formatFileSize(file.size)} · Ready to upload
              </p>
            </div>
            <button
              type="button"
              onClick={() => onFile(null)}
              disabled={disabled}
              aria-label="Remove selected file"
              className="flex h-8 w-8 shrink-0 items-center justify-center rounded-xl text-muted transition hover:bg-surface hover:text-danger"
            >
              <X className="h-4 w-4" />
            </button>
          </div>
          <div className="mt-3 flex gap-2">
            <Button
              type="button"
              variant="secondary"
              size="sm"
              onClick={() => inputRef.current?.click()}
              disabled={disabled}
            >
              Replace file
            </Button>
            <Button
              type="button"
              variant="ghost"
              size="sm"
              onClick={() => cameraRef.current?.click()}
              disabled={disabled}
              className="text-muted"
            >
              <Camera className="h-3.5 w-3.5" />
              Retake
            </Button>
          </div>
        </div>
      ) : (
        <div
          onDragOver={(event) => {
            event.preventDefault()
            if (!disabled) setDragging(true)
          }}
          onDragLeave={() => setDragging(false)}
          onDrop={handleDrop}
          className={cn(
            'relative overflow-hidden rounded-3xl border-2 border-dashed px-5 py-7 text-center transition',
            dragging
              ? 'border-primary bg-primary-soft/50'
              : error
                ? 'border-danger/40 bg-danger/5'
                : 'border-line bg-elevated/50 hover:border-primary/40 hover:bg-primary-soft/20',
            disabled && 'opacity-60',
          )}
        >
          <div className="mx-auto mb-3 flex h-12 w-12 items-center justify-center rounded-2xl bg-surface text-primary-strong shadow-sm">
            <UploadCloud className="h-5 w-5" />
          </div>
          <p className="text-[13.5px] font-semibold text-ink">
            Upload your ID or legal document
          </p>
          <p className="mx-auto mt-1 max-w-[36ch] text-[12px] leading-relaxed text-muted">
            Aadhaar, driving licence, passport or any government ID. JPG, PNG, WEBP or PDF · up to 10 MB.
          </p>
          {existingName ? (
            <p className="mt-2 text-[11px] font-medium text-primary-strong">
              Currently on file: {existingName}
            </p>
          ) : null}
          <div className="mt-4 flex flex-wrap items-center justify-center gap-2">
            <Button
              type="button"
              variant="secondary"
              size="sm"
              onClick={() => inputRef.current?.click()}
              disabled={disabled}
            >
              <UploadCloud className="h-3.5 w-3.5" />
              Browse files
            </Button>
            <Button
              type="button"
              variant="ghost"
              size="sm"
              onClick={() => cameraRef.current?.click()}
              disabled={disabled}
            >
              <Camera className="h-3.5 w-3.5" />
              Take photo
            </Button>
          </div>
          <p className="mt-3 text-[10.5px] font-medium uppercase tracking-[0.14em] text-faint">
            Private · encrypted at rest
          </p>
        </div>
      )}
      {error ? <p className="mt-2 text-xs font-medium text-danger">{error}</p> : null}
    </div>
  )
}
