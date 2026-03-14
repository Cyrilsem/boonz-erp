import BottomTabs from './bottom-tabs'

export default function FieldLayout({
  children,
}: {
  children: React.ReactNode
}) {
  return (
    <div className="flex min-h-screen flex-col pb-12">
      <main className="flex-1">{children}</main>
      <BottomTabs />
    </div>
  )
}
