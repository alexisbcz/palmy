/**
 * THE case registry for the browser-vs-Odin pixel parity harness.
 *
 * Rules (see parity/CONTRACT.md):
 *  - one component instance per case
 *  - `data-parity-root` on the outermost element of the measured thing
 *  - overlays are opened with `defaultOpen` and the root goes on the POPUP
 *  - fully deterministic: no Date.now(), no Math.random(), no network images,
 *    no relative times. Calendars are pinned to 2026-03-15.
 */
import * as React from "react"
import type { ReactNode } from "react"

import {
  AlignCenterIcon,
  AlignLeftIcon,
  ArrowRightIcon,
  BadgeCheckIcon,
  BellIcon,
  BoldIcon,
  CalendarIcon,
  CheckIcon,
  CircleAlertIcon,
  CopyIcon,
  CreditCardIcon,
  DownloadIcon,
  FileTextIcon,
  FolderIcon,
  HouseIcon,
  ImageIcon,
  InboxIcon,
  InfoIcon,
  ItalicIcon,
  LogOutIcon,
  MailIcon,
  PlusIcon,
  RocketIcon,
  SearchIcon,
  SendIcon,
  SettingsIcon,
  StarIcon,
  SunIcon,
  TerminalIcon,
  Trash2Icon,
  TriangleAlertIcon,
  UnderlineIcon,
  UserIcon,
} from "lucide-react"
import { Bar, BarChart, CartesianGrid, Line, LineChart, XAxis } from "recharts"

import {
  Accordion,
  AccordionContent,
  AccordionItem,
  AccordionTrigger,
} from "~/components/ui/accordion"
import {
  AlertDialog,
  AlertDialogAction,
  AlertDialogCancel,
  AlertDialogContent,
  AlertDialogDescription,
  AlertDialogFooter,
  AlertDialogHeader,
  AlertDialogMedia,
  AlertDialogTitle,
} from "~/components/ui/alert-dialog"
import {
  Alert,
  AlertAction,
  AlertDescription,
  AlertTitle,
} from "~/components/ui/alert"
import { AspectRatio } from "~/components/ui/aspect-ratio"
import {
  Attachment,
  AttachmentAction,
  AttachmentActions,
  AttachmentContent,
  AttachmentDescription,
  AttachmentMedia,
  AttachmentTitle,
} from "~/components/ui/attachment"
import {
  Avatar,
  AvatarBadge,
  AvatarFallback,
  AvatarGroup,
  AvatarGroupCount,
} from "~/components/ui/avatar"
import { Badge } from "~/components/ui/badge"
import {
  Breadcrumb,
  BreadcrumbEllipsis,
  BreadcrumbItem,
  BreadcrumbLink,
  BreadcrumbList,
  BreadcrumbPage,
  BreadcrumbSeparator,
} from "~/components/ui/breadcrumb"
import {
  Bubble,
  BubbleContent,
  BubbleGroup,
  BubbleReactions,
} from "~/components/ui/bubble"
import {
  ButtonGroup,
  ButtonGroupSeparator,
  ButtonGroupText,
} from "~/components/ui/button-group"
import { Button } from "~/components/ui/button"
import { Calendar } from "~/components/ui/calendar"
import {
  Card,
  CardAction,
  CardContent,
  CardDescription,
  CardFooter,
  CardHeader,
  CardTitle,
} from "~/components/ui/card"
import {
  Carousel,
  CarouselContent,
  CarouselItem,
} from "~/components/ui/carousel"
import {
  ChartContainer,
  ChartLegend,
  ChartLegendContent,
  ChartTooltip,
  ChartTooltipContent,
  type ChartConfig,
} from "~/components/ui/chart"
import { Checkbox } from "~/components/ui/checkbox"
import {
  Collapsible,
  CollapsibleContent,
  CollapsibleTrigger,
} from "~/components/ui/collapsible"
import {
  Combobox,
  ComboboxChip,
  ComboboxChips,
  ComboboxChipsInput,
  ComboboxContent,
  ComboboxEmpty,
  ComboboxInput,
  ComboboxItem,
  ComboboxList,
} from "~/components/ui/combobox"
import {
  Command,
  CommandDialog,
  CommandEmpty,
  CommandGroup,
  CommandInput,
  CommandItem,
  CommandList,
  CommandSeparator,
  CommandShortcut,
} from "~/components/ui/command"
import {
  ContextMenu,
  ContextMenuCheckboxItem,
  ContextMenuContent,
  ContextMenuGroup,
  ContextMenuItem,
  ContextMenuLabel,
  ContextMenuSeparator,
  ContextMenuShortcut,
  ContextMenuTrigger,
} from "~/components/ui/context-menu"
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "~/components/ui/dialog"
import { DirectionProvider } from "~/components/ui/direction"
import {
  Drawer,
  DrawerContent,
  DrawerDescription,
  DrawerFooter,
  DrawerHeader,
  DrawerTitle,
} from "~/components/ui/drawer"
import {
  DropdownMenu,
  DropdownMenuCheckboxItem,
  DropdownMenuContent,
  DropdownMenuGroup,
  DropdownMenuItem,
  DropdownMenuLabel,
  DropdownMenuRadioGroup,
  DropdownMenuRadioItem,
  DropdownMenuSeparator,
  DropdownMenuShortcut,
  DropdownMenuTrigger,
} from "~/components/ui/dropdown-menu"
import {
  Empty,
  EmptyContent,
  EmptyDescription,
  EmptyHeader,
  EmptyMedia,
  EmptyTitle,
} from "~/components/ui/empty"
import {
  Field,
  FieldContent,
  FieldDescription,
  FieldError,
  FieldGroup,
  FieldLabel,
  FieldLegend,
  FieldSeparator,
  FieldSet,
  FieldTitle,
} from "~/components/ui/field"
import {
  HoverCard,
  HoverCardContent,
  HoverCardTrigger,
} from "~/components/ui/hover-card"
import {
  InputGroup,
  InputGroupAddon,
  InputGroupButton,
  InputGroupInput,
  InputGroupText,
  InputGroupTextarea,
} from "~/components/ui/input-group"
import {
  InputOTP,
  InputOTPGroup,
  InputOTPSeparator,
  InputOTPSlot,
} from "~/components/ui/input-otp"
import { Input } from "~/components/ui/input"
import {
  Item,
  ItemActions,
  ItemContent,
  ItemDescription,
  ItemMedia,
  ItemTitle,
} from "~/components/ui/item"
import { Kbd, KbdGroup } from "~/components/ui/kbd"
import { Label } from "~/components/ui/label"
import { Marker, MarkerContent, MarkerIcon } from "~/components/ui/marker"
import {
  Menubar,
  MenubarContent,
  MenubarItem,
  MenubarMenu,
  MenubarSeparator,
  MenubarShortcut,
  MenubarTrigger,
} from "~/components/ui/menubar"
import {
  MessageScroller,
  MessageScrollerContent,
  MessageScrollerItem,
  MessageScrollerProvider,
  MessageScrollerViewport,
} from "~/components/ui/message-scroller"
import {
  Message,
  MessageAvatar,
  MessageContent,
  MessageFooter,
  MessageHeader,
} from "~/components/ui/message"
import {
  NativeSelect,
  NativeSelectOptGroup,
  NativeSelectOption,
} from "~/components/ui/native-select"
import {
  NavigationMenu,
  NavigationMenuContent,
  NavigationMenuItem,
  NavigationMenuLink,
  NavigationMenuList,
  NavigationMenuTrigger,
} from "~/components/ui/navigation-menu"
import {
  Pagination,
  PaginationContent,
  PaginationEllipsis,
  PaginationItem,
  PaginationLink,
  PaginationNext,
  PaginationPrevious,
} from "~/components/ui/pagination"
import {
  Popover,
  PopoverContent,
  PopoverDescription,
  PopoverHeader,
  PopoverTitle,
  PopoverTrigger,
} from "~/components/ui/popover"
import {
  Progress,
  ProgressLabel,
  ProgressValue,
} from "~/components/ui/progress"
import {
  Questionnaire,
  QuestionnaireActions,
  QuestionnaireChoice,
  QuestionnaireChoiceDescription,
  QuestionnaireChoices,
  QuestionnaireDescription,
  QuestionnaireInput,
  QuestionnaireItem,
  QuestionnaireNext,
  QuestionnairePrevious,
  QuestionnaireProgress,
  QuestionnaireTitle,
} from "~/components/ui/questionnaire"
import { RadioGroup, RadioGroupItem } from "~/components/ui/radio-group"
import {
  ResizableHandle,
  ResizablePanel,
  ResizablePanelGroup,
} from "~/components/ui/resizable"
import { ScrollArea } from "~/components/ui/scroll-area"
import {
  Select,
  SelectContent,
  SelectGroup,
  SelectItem,
  SelectLabel,
  SelectSeparator,
  SelectTrigger,
  SelectValue,
} from "~/components/ui/select"
import { Separator } from "~/components/ui/separator"
import {
  Sheet,
  SheetContent,
  SheetDescription,
  SheetFooter,
  SheetHeader,
  SheetTitle,
} from "~/components/ui/sheet"
import {
  Sidebar,
  SidebarContent,
  SidebarFooter,
  SidebarGroup,
  SidebarGroupContent,
  SidebarGroupLabel,
  SidebarHeader,
  SidebarMenu,
  SidebarMenuBadge,
  SidebarMenuButton,
  SidebarMenuItem,
  SidebarMenuSub,
  SidebarMenuSubButton,
  SidebarMenuSubItem,
  SidebarProvider,
  SidebarSeparator,
} from "~/components/ui/sidebar"
import { Skeleton } from "~/components/ui/skeleton"
import { Slider } from "~/components/ui/slider"
import { Spinner } from "~/components/ui/spinner"
import { Switch } from "~/components/ui/switch"
import {
  Table,
  TableBody,
  TableCaption,
  TableCell,
  TableFooter,
  TableHead,
  TableHeader,
  TableRow,
} from "~/components/ui/table"
import {
  Tabs,
  TabsContent,
  TabsList,
  TabsTrigger,
} from "~/components/ui/tabs"
import { Textarea } from "~/components/ui/textarea"
import {
  Toast,
  ToastAction,
  ToastClose,
  ToastContent,
  ToastDescription,
  ToastPortal,
  ToastProvider,
  ToastTitle,
  ToastViewport,
  createToastManager,
  useToastManager,
} from "~/components/ui/toast"
import { ToggleGroup, ToggleGroupItem } from "~/components/ui/toggle-group"
import { Toggle } from "~/components/ui/toggle"
import {
  Tooltip,
  TooltipContent,
  TooltipProvider,
  TooltipTrigger,
} from "~/components/ui/tooltip"

export type Case = {
  /** kebab, unique, e.g. "button-default" */
  id: string
  /** the ui component this case exercises, e.g. "button" */
  component: string
  title: string
  render: () => ReactNode
}

/* -------------------------------------------------------------------------- */
/* deterministic fixtures                                                     */
/* -------------------------------------------------------------------------- */

/** Pinned "today" for every date-aware component. 2026-03-15, local noon. */
const PINNED_DAY = new Date(2026, 2, 15, 12, 0, 0, 0)
const PINNED_MONTH = new Date(2026, 2, 1, 12, 0, 0, 0)
const PINNED_RANGE_FROM = new Date(2026, 2, 10, 12, 0, 0, 0)
const PINNED_RANGE_TO = new Date(2026, 2, 18, 12, 0, 0, 0)

const FRUITS = ["Apple", "Banana", "Cherry", "Date"]

const CHART_DATA = [
  { month: "Jan", desktop: 120, mobile: 80 },
  { month: "Feb", desktop: 150, mobile: 95 },
  { month: "Mar", desktop: 90, mobile: 70 },
  { month: "Apr", desktop: 170, mobile: 120 },
]

const CHART_CONFIG = {
  desktop: { label: "Desktop", color: "var(--chart-1)" },
  mobile: { label: "Mobile", color: "var(--chart-2)" },
} satisfies ChartConfig

/* -------------------------------------------------------------------------- */
/* toast harness (toasts only exist inside a provider + manager)              */
/* -------------------------------------------------------------------------- */

function ToastSeed({
  title,
  description,
  withAction,
}: {
  title: string
  description: string
  withAction: boolean
}) {
  const { add } = useToastManager()
  React.useEffect(() => {
    add({
      id: "parity-toast",
      title,
      description,
      timeout: 0,
      actionProps: withAction ? { children: "Undo" } : undefined,
    })
  }, [add, title, description, withAction])
  return null
}

function ToastRows({ withAction }: { withAction: boolean }) {
  const { toasts } = useToastManager()
  return (
    <>
      {toasts.map((item) => (
        <Toast key={item.id} toast={item} data-parity-root>
          <ToastContent>
            <div className="flex min-w-0 flex-1 flex-col gap-1">
              <ToastTitle />
              <ToastDescription />
            </div>
            {withAction ? <ToastAction /> : null}
            <ToastClose />
          </ToastContent>
        </Toast>
      ))}
    </>
  )
}

function ToastCase({
  title,
  description,
  withAction = false,
}: {
  title: string
  description: string
  withAction?: boolean
}) {
  const manager = React.useMemo(() => createToastManager(), [])
  return (
    <ToastProvider toastManager={manager} timeout={0}>
      <ToastSeed
        title={title}
        description={description}
        withAction={withAction}
      />
      <ToastPortal>
        <ToastViewport>
          <ToastRows withAction={withAction} />
        </ToastViewport>
      </ToastPortal>
    </ToastProvider>
  )
}

/* -------------------------------------------------------------------------- */
/* the registry                                                               */
/* -------------------------------------------------------------------------- */

export const CASES: Case[] = [
  /* ---------------------------------------------------------------- accordion */
  {
    id: "accordion-default",
    component: "accordion",
    title: "Accordion / first item open",
    render: () => (
      <Accordion data-parity-root defaultValue={[0]} className="w-80">
        <AccordionItem value={0}>
          <AccordionTrigger>Shipping</AccordionTrigger>
          <AccordionContent>Ships in two days.</AccordionContent>
        </AccordionItem>
        <AccordionItem value={1}>
          <AccordionTrigger>Returns</AccordionTrigger>
          <AccordionContent>Thirty day window.</AccordionContent>
        </AccordionItem>
      </Accordion>
    ),
  },
  {
    id: "accordion-closed",
    component: "accordion",
    title: "Accordion / all closed",
    render: () => (
      <Accordion data-parity-root className="w-80">
        <AccordionItem value={0}>
          <AccordionTrigger>Shipping</AccordionTrigger>
          <AccordionContent>Ships in two days.</AccordionContent>
        </AccordionItem>
        <AccordionItem value={1}>
          <AccordionTrigger>Returns</AccordionTrigger>
          <AccordionContent>Thirty day window.</AccordionContent>
        </AccordionItem>
      </Accordion>
    ),
  },
  {
    id: "accordion-multiple",
    component: "accordion",
    title: "Accordion / two items open",
    render: () => (
      <Accordion data-parity-root defaultValue={[0, 1]} className="w-80">
        <AccordionItem value={0}>
          <AccordionTrigger>Shipping</AccordionTrigger>
          <AccordionContent>Ships in two days.</AccordionContent>
        </AccordionItem>
        <AccordionItem value={1}>
          <AccordionTrigger>Returns</AccordionTrigger>
          <AccordionContent>Thirty day window.</AccordionContent>
        </AccordionItem>
      </Accordion>
    ),
  },

  /* ------------------------------------------------------------- alert-dialog */
  {
    id: "alert-dialog-default",
    component: "alert-dialog",
    title: "Alert dialog / default size",
    render: () => (
      <AlertDialog defaultOpen>
        <AlertDialogContent data-parity-root>
          <AlertDialogHeader>
            <AlertDialogTitle>Delete project?</AlertDialogTitle>
            <AlertDialogDescription>
              This removes the project and all of its files.
            </AlertDialogDescription>
          </AlertDialogHeader>
          <AlertDialogFooter>
            <AlertDialogCancel>Cancel</AlertDialogCancel>
            <AlertDialogAction>Delete</AlertDialogAction>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>
    ),
  },
  {
    id: "alert-dialog-sm",
    component: "alert-dialog",
    title: "Alert dialog / small",
    render: () => (
      <AlertDialog defaultOpen>
        <AlertDialogContent data-parity-root size="sm">
          <AlertDialogHeader>
            <AlertDialogTitle>Sign out?</AlertDialogTitle>
            <AlertDialogDescription>
              You can sign back in later.
            </AlertDialogDescription>
          </AlertDialogHeader>
          <AlertDialogFooter>
            <AlertDialogCancel>Cancel</AlertDialogCancel>
            <AlertDialogAction>Sign out</AlertDialogAction>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>
    ),
  },
  {
    id: "alert-dialog-media",
    component: "alert-dialog",
    title: "Alert dialog / with media",
    render: () => (
      <AlertDialog defaultOpen>
        <AlertDialogContent data-parity-root>
          <AlertDialogHeader>
            <AlertDialogMedia>
              <TriangleAlertIcon />
            </AlertDialogMedia>
            <AlertDialogTitle>Quota reached</AlertDialogTitle>
            <AlertDialogDescription>
              Upgrade the plan to keep deploying.
            </AlertDialogDescription>
          </AlertDialogHeader>
          <AlertDialogFooter>
            <AlertDialogCancel>Later</AlertDialogCancel>
            <AlertDialogAction>Upgrade</AlertDialogAction>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>
    ),
  },

  /* -------------------------------------------------------------------- alert */
  {
    id: "alert-default",
    component: "alert",
    title: "Alert / default",
    render: () => (
      <Alert data-parity-root className="w-96">
        <AlertTitle>Heads up</AlertTitle>
        <AlertDescription>The build finished in 12 seconds.</AlertDescription>
      </Alert>
    ),
  },
  {
    id: "alert-destructive",
    component: "alert",
    title: "Alert / destructive",
    render: () => (
      <Alert data-parity-root variant="destructive" className="w-96">
        <CircleAlertIcon />
        <AlertTitle>Build failed</AlertTitle>
        <AlertDescription>Two tests did not pass.</AlertDescription>
      </Alert>
    ),
  },
  {
    id: "alert-with-icon",
    component: "alert",
    title: "Alert / icon and action",
    render: () => (
      <Alert data-parity-root className="w-96">
        <InfoIcon />
        <AlertTitle>New version</AlertTitle>
        <AlertDescription>Version 2.1 is available.</AlertDescription>
        <AlertAction>
          <Button size="xs" variant="outline">
            Update
          </Button>
        </AlertAction>
      </Alert>
    ),
  },

  /* ------------------------------------------------------------- aspect-ratio */
  {
    id: "aspect-ratio-16-9",
    component: "aspect-ratio",
    title: "Aspect ratio / 16:9",
    render: () => (
      <AspectRatio
        data-parity-root
        ratio={16 / 9}
        className="w-80 rounded-lg bg-muted"
      />
    ),
  },
  {
    id: "aspect-ratio-1-1",
    component: "aspect-ratio",
    title: "Aspect ratio / 1:1",
    render: () => (
      <AspectRatio
        data-parity-root
        ratio={1}
        className="w-48 rounded-lg bg-muted"
      />
    ),
  },

  /* --------------------------------------------------------------- attachment */
  {
    id: "attachment-default",
    component: "attachment",
    title: "Attachment / default",
    render: () => (
      <Attachment data-parity-root>
        <AttachmentMedia>
          <FileTextIcon />
        </AttachmentMedia>
        <AttachmentContent>
          <AttachmentTitle>report.pdf</AttachmentTitle>
          <AttachmentDescription>248 KB</AttachmentDescription>
        </AttachmentContent>
        <AttachmentActions>
          <AttachmentAction>
            <Trash2Icon />
          </AttachmentAction>
        </AttachmentActions>
      </Attachment>
    ),
  },
  {
    id: "attachment-sm",
    component: "attachment",
    title: "Attachment / small",
    render: () => (
      <Attachment data-parity-root size="sm">
        <AttachmentMedia>
          <FileTextIcon />
        </AttachmentMedia>
        <AttachmentContent>
          <AttachmentTitle>notes.txt</AttachmentTitle>
          <AttachmentDescription>12 KB</AttachmentDescription>
        </AttachmentContent>
      </Attachment>
    ),
  },
  {
    id: "attachment-xs",
    component: "attachment",
    title: "Attachment / extra small",
    render: () => (
      <Attachment data-parity-root size="xs">
        <AttachmentMedia>
          <ImageIcon />
        </AttachmentMedia>
        <AttachmentContent>
          <AttachmentTitle>cover.png</AttachmentTitle>
        </AttachmentContent>
      </Attachment>
    ),
  },
  {
    id: "attachment-vertical",
    component: "attachment",
    title: "Attachment / vertical",
    render: () => (
      <Attachment data-parity-root orientation="vertical">
        <AttachmentMedia>
          <ImageIcon />
        </AttachmentMedia>
        <AttachmentContent>
          <AttachmentTitle>cover.png</AttachmentTitle>
          <AttachmentDescription>1.2 MB</AttachmentDescription>
        </AttachmentContent>
      </Attachment>
    ),
  },
  {
    id: "attachment-error",
    component: "attachment",
    title: "Attachment / error state",
    render: () => (
      <Attachment data-parity-root state="error">
        <AttachmentMedia>
          <TriangleAlertIcon />
        </AttachmentMedia>
        <AttachmentContent>
          <AttachmentTitle>huge.zip</AttachmentTitle>
          <AttachmentDescription>Upload failed</AttachmentDescription>
        </AttachmentContent>
      </Attachment>
    ),
  },

  /* ------------------------------------------------------------------- avatar */
  {
    id: "avatar-default",
    component: "avatar",
    title: "Avatar / default",
    render: () => (
      <Avatar data-parity-root>
        <AvatarFallback>CN</AvatarFallback>
      </Avatar>
    ),
  },
  {
    id: "avatar-sm",
    component: "avatar",
    title: "Avatar / small",
    render: () => (
      <Avatar data-parity-root size="sm">
        <AvatarFallback>AB</AvatarFallback>
      </Avatar>
    ),
  },
  {
    id: "avatar-lg",
    component: "avatar",
    title: "Avatar / large",
    render: () => (
      <Avatar data-parity-root size="lg">
        <AvatarFallback>XY</AvatarFallback>
      </Avatar>
    ),
  },
  {
    id: "avatar-badge",
    component: "avatar",
    title: "Avatar / with badge",
    render: () => (
      <Avatar data-parity-root>
        <AvatarFallback>CN</AvatarFallback>
        <AvatarBadge />
      </Avatar>
    ),
  },
  {
    id: "avatar-group",
    component: "avatar",
    title: "Avatar / group with count",
    render: () => (
      <AvatarGroup data-parity-root>
        <Avatar>
          <AvatarFallback>CN</AvatarFallback>
        </Avatar>
        <Avatar>
          <AvatarFallback>AB</AvatarFallback>
        </Avatar>
        <Avatar>
          <AvatarFallback>XY</AvatarFallback>
        </Avatar>
        <AvatarGroupCount>+3</AvatarGroupCount>
      </AvatarGroup>
    ),
  },

  /* -------------------------------------------------------------------- badge */
  {
    id: "badge-default",
    component: "badge",
    title: "Badge / default",
    render: () => <Badge data-parity-root>Badge</Badge>,
  },
  {
    id: "badge-secondary",
    component: "badge",
    title: "Badge / secondary",
    render: () => (
      <Badge data-parity-root variant="secondary">
        Badge
      </Badge>
    ),
  },
  {
    id: "badge-destructive",
    component: "badge",
    title: "Badge / destructive",
    render: () => (
      <Badge data-parity-root variant="destructive">
        Badge
      </Badge>
    ),
  },
  {
    id: "badge-outline",
    component: "badge",
    title: "Badge / outline",
    render: () => (
      <Badge data-parity-root variant="outline">
        Badge
      </Badge>
    ),
  },
  {
    id: "badge-ghost",
    component: "badge",
    title: "Badge / ghost",
    render: () => (
      <Badge data-parity-root variant="ghost">
        Badge
      </Badge>
    ),
  },
  {
    id: "badge-link",
    component: "badge",
    title: "Badge / link",
    render: () => (
      <Badge data-parity-root variant="link">
        Badge
      </Badge>
    ),
  },
  {
    id: "badge-icon",
    component: "badge",
    title: "Badge / with icon",
    render: () => (
      <Badge data-parity-root variant="secondary">
        <BadgeCheckIcon />
        Verified
      </Badge>
    ),
  },
  {
    id: "badge-notification",
    component: "badge",
    title: "Badge / notification count",
    render: () => (
      <Badge data-parity-root variant="destructive">
        <BellIcon />9
      </Badge>
    ),
  },

  /* --------------------------------------------------------------- breadcrumb */
  {
    id: "breadcrumb-default",
    component: "breadcrumb",
    title: "Breadcrumb / default",
    render: () => (
      <Breadcrumb data-parity-root>
        <BreadcrumbList>
          <BreadcrumbItem>
            <BreadcrumbLink href="#">Home</BreadcrumbLink>
          </BreadcrumbItem>
          <BreadcrumbSeparator />
          <BreadcrumbItem>
            <BreadcrumbLink href="#">Docs</BreadcrumbLink>
          </BreadcrumbItem>
          <BreadcrumbSeparator />
          <BreadcrumbItem>
            <BreadcrumbPage>Button</BreadcrumbPage>
          </BreadcrumbItem>
        </BreadcrumbList>
      </Breadcrumb>
    ),
  },
  {
    id: "breadcrumb-ellipsis",
    component: "breadcrumb",
    title: "Breadcrumb / with ellipsis",
    render: () => (
      <Breadcrumb data-parity-root>
        <BreadcrumbList>
          <BreadcrumbItem>
            <BreadcrumbLink href="#">Home</BreadcrumbLink>
          </BreadcrumbItem>
          <BreadcrumbSeparator />
          <BreadcrumbItem>
            <BreadcrumbEllipsis />
          </BreadcrumbItem>
          <BreadcrumbSeparator />
          <BreadcrumbItem>
            <BreadcrumbPage>Button</BreadcrumbPage>
          </BreadcrumbItem>
        </BreadcrumbList>
      </Breadcrumb>
    ),
  },

  /* ------------------------------------------------------------------- bubble */
  {
    id: "bubble-default",
    component: "bubble",
    title: "Bubble / default",
    render: () => (
      <Bubble data-parity-root className="w-64">
        <BubbleContent>Hello there.</BubbleContent>
      </Bubble>
    ),
  },
  {
    id: "bubble-secondary",
    component: "bubble",
    title: "Bubble / secondary",
    render: () => (
      <Bubble data-parity-root variant="secondary" className="w-64">
        <BubbleContent>Hello there.</BubbleContent>
      </Bubble>
    ),
  },
  {
    id: "bubble-outline",
    component: "bubble",
    title: "Bubble / outline",
    render: () => (
      <Bubble data-parity-root variant="outline" className="w-64">
        <BubbleContent>Hello there.</BubbleContent>
      </Bubble>
    ),
  },
  {
    id: "bubble-group",
    component: "bubble",
    title: "Bubble / group with reactions",
    render: () => (
      <BubbleGroup data-parity-root className="w-72">
        <Bubble variant="muted">
          <BubbleContent>Can you review the patch?</BubbleContent>
        </Bubble>
        <Bubble align="end">
          <BubbleContent>On it.</BubbleContent>
          <BubbleReactions>OK</BubbleReactions>
        </Bubble>
      </BubbleGroup>
    ),
  },

  /* ------------------------------------------------------------- button-group */
  {
    id: "button-group-horizontal",
    component: "button-group",
    title: "Button group / horizontal",
    render: () => (
      <ButtonGroup data-parity-root>
        <Button variant="outline">Left</Button>
        <Button variant="outline">Middle</Button>
        <Button variant="outline">Right</Button>
      </ButtonGroup>
    ),
  },
  {
    id: "button-group-vertical",
    component: "button-group",
    title: "Button group / vertical",
    render: () => (
      <ButtonGroup data-parity-root orientation="vertical">
        <Button variant="outline">Top</Button>
        <Button variant="outline">Middle</Button>
        <Button variant="outline">Bottom</Button>
      </ButtonGroup>
    ),
  },
  {
    id: "button-group-text",
    component: "button-group",
    title: "Button group / text and separator",
    render: () => (
      <ButtonGroup data-parity-root>
        <ButtonGroupText>https://</ButtonGroupText>
        <Button variant="outline">Copy</Button>
        <ButtonGroupSeparator />
        <Button variant="outline">Open</Button>
      </ButtonGroup>
    ),
  },

  /* ------------------------------------------------------------------- button */
  {
    id: "button-default",
    component: "button",
    title: "Button / default",
    render: () => <Button data-parity-root>Button</Button>,
  },
  {
    id: "button-secondary",
    component: "button",
    title: "Button / secondary",
    render: () => (
      <Button data-parity-root variant="secondary">
        Button
      </Button>
    ),
  },
  {
    id: "button-destructive",
    component: "button",
    title: "Button / destructive",
    render: () => (
      <Button data-parity-root variant="destructive">
        Button
      </Button>
    ),
  },
  {
    id: "button-outline",
    component: "button",
    title: "Button / outline",
    render: () => (
      <Button data-parity-root variant="outline">
        Button
      </Button>
    ),
  },
  {
    id: "button-ghost",
    component: "button",
    title: "Button / ghost",
    render: () => (
      <Button data-parity-root variant="ghost">
        Button
      </Button>
    ),
  },
  {
    id: "button-link",
    component: "button",
    title: "Button / link",
    render: () => (
      <Button data-parity-root variant="link">
        Button
      </Button>
    ),
  },
  {
    id: "button-xs",
    component: "button",
    title: "Button / size xs",
    render: () => (
      <Button data-parity-root size="xs">
        Button
      </Button>
    ),
  },
  {
    id: "button-sm",
    component: "button",
    title: "Button / size sm",
    render: () => (
      <Button data-parity-root size="sm">
        Button
      </Button>
    ),
  },
  {
    id: "button-lg",
    component: "button",
    title: "Button / size lg",
    render: () => (
      <Button data-parity-root size="lg">
        Button
      </Button>
    ),
  },
  {
    id: "button-icon",
    component: "button",
    title: "Button / icon",
    render: () => (
      <Button data-parity-root size="icon" variant="outline">
        <PlusIcon />
      </Button>
    ),
  },
  {
    id: "button-icon-sm",
    component: "button",
    title: "Button / icon sm",
    render: () => (
      <Button data-parity-root size="icon-sm" variant="ghost">
        <SettingsIcon />
      </Button>
    ),
  },
  {
    id: "button-with-icon",
    component: "button",
    title: "Button / leading icon",
    render: () => (
      <Button data-parity-root>
        <SendIcon data-icon="inline-start" />
        Send
      </Button>
    ),
  },
  {
    id: "button-disabled",
    component: "button",
    title: "Button / disabled",
    render: () => (
      <Button data-parity-root disabled>
        Button
      </Button>
    ),
  },

  /* ----------------------------------------------------------------- calendar */
  {
    id: "calendar-default",
    component: "calendar",
    title: "Calendar / single, 2026-03-15",
    render: () => (
      <Calendar
        data-parity-root
        mode="single"
        selected={PINNED_DAY}
        month={PINNED_MONTH}
        today={PINNED_DAY}
      />
    ),
  },
  {
    id: "calendar-range",
    component: "calendar",
    title: "Calendar / range 10-18 March 2026",
    render: () => (
      <Calendar
        data-parity-root
        mode="range"
        selected={{ from: PINNED_RANGE_FROM, to: PINNED_RANGE_TO }}
        month={PINNED_MONTH}
        today={PINNED_DAY}
      />
    ),
  },
  {
    id: "calendar-dropdown",
    component: "calendar",
    title: "Calendar / dropdown caption",
    render: () => (
      <Calendar
        data-parity-root
        mode="single"
        captionLayout="dropdown"
        selected={PINNED_DAY}
        month={PINNED_MONTH}
        today={PINNED_DAY}
        startMonth={new Date(2024, 0, 1)}
        endMonth={new Date(2028, 11, 1)}
      />
    ),
  },

  /* --------------------------------------------------------------------- card */
  {
    id: "card-default",
    component: "card",
    title: "Card / default",
    render: () => (
      <Card data-parity-root className="w-80">
        <CardHeader>
          <CardTitle>Monthly report</CardTitle>
          <CardDescription>Totals for March 2026.</CardDescription>
        </CardHeader>
        <CardContent>Revenue is up by nine percent.</CardContent>
      </Card>
    ),
  },
  {
    id: "card-sm",
    component: "card",
    title: "Card / small",
    render: () => (
      <Card data-parity-root size="sm" className="w-72">
        <CardHeader>
          <CardTitle>Monthly report</CardTitle>
          <CardDescription>Totals for March 2026.</CardDescription>
        </CardHeader>
        <CardContent>Revenue is up by nine percent.</CardContent>
      </Card>
    ),
  },
  {
    id: "card-footer",
    component: "card",
    title: "Card / action and footer",
    render: () => (
      <Card data-parity-root className="w-80">
        <CardHeader>
          <CardTitle>Monthly report</CardTitle>
          <CardDescription>Totals for March 2026.</CardDescription>
          <CardAction>
            <Button size="icon-sm" variant="ghost">
              <SettingsIcon />
            </Button>
          </CardAction>
        </CardHeader>
        <CardContent>Revenue is up by nine percent.</CardContent>
        <CardFooter>
          <Button size="sm">Download</Button>
        </CardFooter>
      </Card>
    ),
  },

  /* ----------------------------------------------------------------- carousel */
  {
    id: "carousel-default",
    component: "carousel",
    title: "Carousel / three slides",
    render: () => (
      <Carousel data-parity-root className="w-72">
        <CarouselContent>
          <CarouselItem>
            <Card size="sm">
              <CardContent>One</CardContent>
            </Card>
          </CarouselItem>
          <CarouselItem>
            <Card size="sm">
              <CardContent>Two</CardContent>
            </Card>
          </CarouselItem>
          <CarouselItem>
            <Card size="sm">
              <CardContent>Three</CardContent>
            </Card>
          </CarouselItem>
        </CarouselContent>
      </Carousel>
    ),
  },

  /* -------------------------------------------------------------------- chart */
  {
    id: "chart-bar",
    component: "chart",
    title: "Chart / bar",
    render: () => (
      <ChartContainer
        data-parity-root
        config={CHART_CONFIG}
        className="h-[220px] w-[380px]"
      >
        <BarChart data={CHART_DATA}>
          <CartesianGrid vertical={false} />
          <XAxis dataKey="month" tickLine={false} axisLine={false} />
          <ChartTooltip content={<ChartTooltipContent />} />
          <ChartLegend content={<ChartLegendContent />} />
          <Bar dataKey="desktop" fill="var(--color-desktop)" radius={4} />
          <Bar dataKey="mobile" fill="var(--color-mobile)" radius={4} />
        </BarChart>
      </ChartContainer>
    ),
  },
  {
    id: "chart-line",
    component: "chart",
    title: "Chart / line",
    render: () => (
      <ChartContainer
        data-parity-root
        config={CHART_CONFIG}
        className="h-[220px] w-[380px]"
      >
        <LineChart data={CHART_DATA}>
          <CartesianGrid vertical={false} />
          <XAxis dataKey="month" tickLine={false} axisLine={false} />
          <Line
            dataKey="desktop"
            stroke="var(--color-desktop)"
            dot={false}
            isAnimationActive={false}
          />
          <Line
            dataKey="mobile"
            stroke="var(--color-mobile)"
            dot={false}
            isAnimationActive={false}
          />
        </LineChart>
      </ChartContainer>
    ),
  },

  /* ----------------------------------------------------------------- checkbox */
  {
    id: "checkbox-default",
    component: "checkbox",
    title: "Checkbox / unchecked",
    render: () => <Checkbox data-parity-root />,
  },
  {
    id: "checkbox-checked",
    component: "checkbox",
    title: "Checkbox / checked",
    render: () => <Checkbox data-parity-root defaultChecked />,
  },
  {
    id: "checkbox-indeterminate",
    component: "checkbox",
    title: "Checkbox / indeterminate",
    render: () => <Checkbox data-parity-root indeterminate defaultChecked />,
  },
  {
    id: "checkbox-disabled",
    component: "checkbox",
    title: "Checkbox / disabled checked",
    render: () => <Checkbox data-parity-root defaultChecked disabled />,
  },

  /* -------------------------------------------------------------- collapsible */
  {
    id: "collapsible-open",
    component: "collapsible",
    title: "Collapsible / open",
    render: () => (
      <Collapsible
        data-parity-root
        defaultOpen
        className="flex w-72 flex-col gap-2"
      >
        <CollapsibleTrigger render={<Button variant="outline" />}>
          Details
        </CollapsibleTrigger>
        <CollapsibleContent className="text-sm">
          Four files changed.
        </CollapsibleContent>
      </Collapsible>
    ),
  },
  {
    id: "collapsible-closed",
    component: "collapsible",
    title: "Collapsible / closed",
    render: () => (
      <Collapsible data-parity-root className="flex w-72 flex-col gap-2">
        <CollapsibleTrigger render={<Button variant="outline" />}>
          Details
        </CollapsibleTrigger>
        <CollapsibleContent className="text-sm">
          Four files changed.
        </CollapsibleContent>
      </Collapsible>
    ),
  },

  /* ----------------------------------------------------------------- combobox */
  {
    id: "combobox-open",
    component: "combobox",
    title: "Combobox / open list",
    render: () => (
      <Combobox defaultOpen items={FRUITS}>
        <ComboboxInput placeholder="Fruit" className="w-56" />
        <ComboboxContent data-parity-root>
          <ComboboxEmpty>No results.</ComboboxEmpty>
          <ComboboxList>
            {(item: string) => (
              <ComboboxItem key={item} value={item}>
                {item}
              </ComboboxItem>
            )}
          </ComboboxList>
        </ComboboxContent>
      </Combobox>
    ),
  },
  {
    id: "combobox-empty",
    component: "combobox",
    title: "Combobox / empty list",
    render: () => (
      <Combobox defaultOpen items={[]}>
        <ComboboxInput placeholder="Fruit" className="w-56" />
        <ComboboxContent data-parity-root>
          <ComboboxEmpty>No results.</ComboboxEmpty>
          <ComboboxList>
            {(item: string) => (
              <ComboboxItem key={item} value={item}>
                {item}
              </ComboboxItem>
            )}
          </ComboboxList>
        </ComboboxContent>
      </Combobox>
    ),
  },
  {
    id: "combobox-chips",
    component: "combobox",
    title: "Combobox / chips",
    render: () => (
      <Combobox multiple defaultValue={["Apple", "Cherry"]} items={FRUITS}>
        <ComboboxChips data-parity-root className="w-72">
          <ComboboxChip>Apple</ComboboxChip>
          <ComboboxChip>Cherry</ComboboxChip>
          <ComboboxChipsInput placeholder="Add" />
        </ComboboxChips>
      </Combobox>
    ),
  },

  /* ------------------------------------------------------------------ command */
  {
    id: "command-default",
    component: "command",
    title: "Command / inline",
    render: () => (
      <Command data-parity-root className="w-80 ring-1 ring-foreground/10">
        <CommandInput placeholder="Type a command" />
        <CommandList>
          <CommandEmpty>No results.</CommandEmpty>
          <CommandGroup heading="Suggestions">
            <CommandItem>
              <CalendarIcon />
              Calendar
            </CommandItem>
            <CommandItem>
              <MailIcon />
              Mail
            </CommandItem>
          </CommandGroup>
          <CommandSeparator />
          <CommandGroup heading="Settings">
            <CommandItem>
              <UserIcon />
              Profile
              <CommandShortcut>P</CommandShortcut>
            </CommandItem>
          </CommandGroup>
        </CommandList>
      </Command>
    ),
  },
  {
    id: "command-dialog",
    component: "command",
    title: "Command / dialog",
    render: () => (
      <CommandDialog defaultOpen>
        <Command data-parity-root>
          <CommandInput placeholder="Type a command" />
          <CommandList>
            <CommandEmpty>No results.</CommandEmpty>
            <CommandGroup heading="Suggestions">
              <CommandItem>
                <CalendarIcon />
                Calendar
              </CommandItem>
              <CommandItem>
                <TerminalIcon />
                Terminal
                <CommandShortcut>T</CommandShortcut>
              </CommandItem>
            </CommandGroup>
          </CommandList>
        </Command>
      </CommandDialog>
    ),
  },

  /* ------------------------------------------------------------- context-menu */
  {
    id: "context-menu-open",
    component: "context-menu",
    title: "Context menu / open",
    render: () => (
      <ContextMenu defaultOpen>
        <ContextMenuTrigger className="flex h-24 w-56 items-center justify-center rounded-lg border border-dashed text-sm">
          Right click
        </ContextMenuTrigger>
        <ContextMenuContent data-parity-root>
          <ContextMenuGroup>
            <ContextMenuLabel>Actions</ContextMenuLabel>
            <ContextMenuItem>
              <CopyIcon />
              Copy
              <ContextMenuShortcut>C</ContextMenuShortcut>
            </ContextMenuItem>
            <ContextMenuItem>
              <DownloadIcon />
              Download
            </ContextMenuItem>
          </ContextMenuGroup>
          <ContextMenuSeparator />
          <ContextMenuItem variant="destructive">
            <Trash2Icon />
            Delete
          </ContextMenuItem>
        </ContextMenuContent>
      </ContextMenu>
    ),
  },
  {
    id: "context-menu-checkbox",
    component: "context-menu",
    title: "Context menu / checkbox items",
    render: () => (
      <ContextMenu defaultOpen>
        <ContextMenuTrigger className="flex h-24 w-56 items-center justify-center rounded-lg border border-dashed text-sm">
          Right click
        </ContextMenuTrigger>
        <ContextMenuContent data-parity-root>
          <ContextMenuCheckboxItem checked>Show grid</ContextMenuCheckboxItem>
          <ContextMenuCheckboxItem>Show rulers</ContextMenuCheckboxItem>
          <ContextMenuSeparator />
          <ContextMenuItem>Reset</ContextMenuItem>
        </ContextMenuContent>
      </ContextMenu>
    ),
  },

  /* ------------------------------------------------------------------- dialog */
  {
    id: "dialog-default",
    component: "dialog",
    title: "Dialog / default",
    render: () => (
      <Dialog defaultOpen>
        <DialogContent data-parity-root>
          <DialogHeader>
            <DialogTitle>Edit profile</DialogTitle>
            <DialogDescription>
              Change the name shown on your account.
            </DialogDescription>
          </DialogHeader>
          <Input defaultValue="Ada Lovelace" />
        </DialogContent>
      </Dialog>
    ),
  },
  {
    id: "dialog-footer",
    component: "dialog",
    title: "Dialog / with footer",
    render: () => (
      <Dialog defaultOpen>
        <DialogContent data-parity-root>
          <DialogHeader>
            <DialogTitle>Edit profile</DialogTitle>
            <DialogDescription>
              Change the name shown on your account.
            </DialogDescription>
          </DialogHeader>
          <DialogFooter>
            <Button variant="outline">Cancel</Button>
            <Button>Save</Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    ),
  },

  /* ---------------------------------------------------------------- direction */
  {
    id: "direction-rtl",
    component: "direction",
    title: "Direction provider / rtl slider",
    render: () => (
      <DirectionProvider direction="rtl">
        <Slider data-parity-root defaultValue={30} className="w-64" />
      </DirectionProvider>
    ),
  },

  /* ------------------------------------------------------------------- drawer */
  {
    id: "drawer-bottom",
    component: "drawer",
    title: "Drawer / bottom",
    render: () => (
      <Drawer defaultOpen swipeDirection="down">
        <DrawerContent data-parity-root>
          <DrawerHeader>
            <DrawerTitle>Share link</DrawerTitle>
            <DrawerDescription>Anyone can view this page.</DrawerDescription>
          </DrawerHeader>
          <DrawerFooter>
            <Button>Copy link</Button>
          </DrawerFooter>
        </DrawerContent>
      </Drawer>
    ),
  },
  {
    id: "drawer-right",
    component: "drawer",
    title: "Drawer / right",
    render: () => (
      <Drawer defaultOpen swipeDirection="right">
        <DrawerContent data-parity-root>
          <DrawerHeader>
            <DrawerTitle>Share link</DrawerTitle>
            <DrawerDescription>Anyone can view this page.</DrawerDescription>
          </DrawerHeader>
          <DrawerFooter>
            <Button>Copy link</Button>
          </DrawerFooter>
        </DrawerContent>
      </Drawer>
    ),
  },

  /* ------------------------------------------------------------ dropdown-menu */
  {
    id: "dropdown-menu-open",
    component: "dropdown-menu",
    title: "Dropdown menu / open",
    render: () => (
      <DropdownMenu defaultOpen>
        <DropdownMenuTrigger render={<Button variant="outline" />}>
          Open
        </DropdownMenuTrigger>
        <DropdownMenuContent data-parity-root className="w-48">
          <DropdownMenuGroup>
            <DropdownMenuLabel>My account</DropdownMenuLabel>
            <DropdownMenuItem>
              <UserIcon />
              Profile
              <DropdownMenuShortcut>P</DropdownMenuShortcut>
            </DropdownMenuItem>
            <DropdownMenuItem>
              <CreditCardIcon />
              Billing
            </DropdownMenuItem>
          </DropdownMenuGroup>
          <DropdownMenuSeparator />
          <DropdownMenuItem variant="destructive">
            <LogOutIcon />
            Sign out
          </DropdownMenuItem>
        </DropdownMenuContent>
      </DropdownMenu>
    ),
  },
  {
    id: "dropdown-menu-checkbox",
    component: "dropdown-menu",
    title: "Dropdown menu / checkbox items",
    render: () => (
      <DropdownMenu defaultOpen>
        <DropdownMenuTrigger render={<Button variant="outline" />}>
          View
        </DropdownMenuTrigger>
        <DropdownMenuContent data-parity-root className="w-48">
          <DropdownMenuGroup>
            <DropdownMenuLabel>Columns</DropdownMenuLabel>
            <DropdownMenuCheckboxItem checked>Name</DropdownMenuCheckboxItem>
            <DropdownMenuCheckboxItem>Email</DropdownMenuCheckboxItem>
            <DropdownMenuCheckboxItem checked>Role</DropdownMenuCheckboxItem>
          </DropdownMenuGroup>
        </DropdownMenuContent>
      </DropdownMenu>
    ),
  },
  {
    id: "dropdown-menu-radio",
    component: "dropdown-menu",
    title: "Dropdown menu / radio items",
    render: () => (
      <DropdownMenu defaultOpen>
        <DropdownMenuTrigger render={<Button variant="outline" />}>
          Theme
        </DropdownMenuTrigger>
        <DropdownMenuContent data-parity-root className="w-48">
          <DropdownMenuRadioGroup defaultValue="light">
            <DropdownMenuRadioItem value="light">Light</DropdownMenuRadioItem>
            <DropdownMenuRadioItem value="dark">Dark</DropdownMenuRadioItem>
            <DropdownMenuRadioItem value="system">System</DropdownMenuRadioItem>
          </DropdownMenuRadioGroup>
        </DropdownMenuContent>
      </DropdownMenu>
    ),
  },

  /* -------------------------------------------------------------------- empty */
  {
    id: "empty-default",
    component: "empty",
    title: "Empty / default",
    render: () => (
      <Empty data-parity-root className="w-96 border">
        <EmptyHeader>
          <EmptyTitle>No projects</EmptyTitle>
          <EmptyDescription>Create one to get started.</EmptyDescription>
        </EmptyHeader>
        <EmptyContent>
          <Button size="sm">New project</Button>
        </EmptyContent>
      </Empty>
    ),
  },
  {
    id: "empty-icon",
    component: "empty",
    title: "Empty / icon media",
    render: () => (
      <Empty data-parity-root className="w-96 border">
        <EmptyHeader>
          <EmptyMedia variant="icon">
            <InboxIcon />
          </EmptyMedia>
          <EmptyTitle>Inbox is clear</EmptyTitle>
          <EmptyDescription>Nothing left to read.</EmptyDescription>
        </EmptyHeader>
      </Empty>
    ),
  },

  /* -------------------------------------------------------------------- field */
  {
    id: "field-vertical",
    component: "field",
    title: "Field / vertical",
    render: () => (
      <Field data-parity-root className="w-80">
        <FieldLabel htmlFor="field-vertical-input">Email</FieldLabel>
        <Input id="field-vertical-input" placeholder="ada@example.com" />
        <FieldDescription>We never share this address.</FieldDescription>
      </Field>
    ),
  },
  {
    id: "field-horizontal",
    component: "field",
    title: "Field / horizontal",
    render: () => (
      <Field data-parity-root orientation="horizontal" className="w-80">
        <Switch id="field-horizontal-switch" />
        <FieldContent>
          <FieldTitle>Notifications</FieldTitle>
          <FieldDescription>Send a weekly digest.</FieldDescription>
        </FieldContent>
      </Field>
    ),
  },
  {
    id: "field-error",
    component: "field",
    title: "Field / error",
    render: () => (
      <Field data-parity-root className="w-80" data-invalid="true">
        <FieldLabel htmlFor="field-error-input">Email</FieldLabel>
        <Input id="field-error-input" aria-invalid defaultValue="nope" />
        <FieldError errors={[{ message: "Enter a valid address." }]} />
      </Field>
    ),
  },
  {
    id: "field-group",
    component: "field",
    title: "Field / group with separator",
    render: () => (
      <FieldGroup data-parity-root className="w-80">
        <Field>
          <FieldLabel htmlFor="field-group-name">Name</FieldLabel>
          <Input id="field-group-name" placeholder="Ada" />
        </Field>
        <FieldSeparator>or</FieldSeparator>
        <Field>
          <FieldLabel htmlFor="field-group-email">Email</FieldLabel>
          <Input id="field-group-email" placeholder="ada@example.com" />
        </Field>
      </FieldGroup>
    ),
  },
  {
    id: "field-set",
    component: "field",
    title: "Field / fieldset and legend",
    render: () => (
      <FieldSet data-parity-root className="w-80">
        <FieldLegend>Address</FieldLegend>
        <FieldDescription>Where should we ship it?</FieldDescription>
        <FieldGroup>
          <Field>
            <FieldLabel htmlFor="field-set-city">City</FieldLabel>
            <Input id="field-set-city" placeholder="Paris" />
          </Field>
        </FieldGroup>
      </FieldSet>
    ),
  },

  /* --------------------------------------------------------------- hover-card */
  {
    id: "hover-card-open",
    component: "hover-card",
    title: "Hover card / open",
    render: () => (
      <HoverCard defaultOpen>
        <HoverCardTrigger render={<Button variant="link" />}>
          @ada
        </HoverCardTrigger>
        <HoverCardContent data-parity-root>
          <div className="flex gap-2">
            <Avatar size="sm">
              <AvatarFallback>AL</AvatarFallback>
            </Avatar>
            <div className="text-sm">
              <div className="font-medium">Ada Lovelace</div>
              <div className="text-muted-foreground">First programmer.</div>
            </div>
          </div>
        </HoverCardContent>
      </HoverCard>
    ),
  },

  /* -------------------------------------------------------------- input-group */
  {
    id: "input-group-icon",
    component: "input-group",
    title: "Input group / leading icon",
    render: () => (
      <InputGroup data-parity-root className="w-72">
        <InputGroupAddon>
          <SearchIcon />
        </InputGroupAddon>
        <InputGroupInput placeholder="Search" />
      </InputGroup>
    ),
  },
  {
    id: "input-group-button",
    component: "input-group",
    title: "Input group / trailing button",
    render: () => (
      <InputGroup data-parity-root className="w-72">
        <InputGroupInput placeholder="Enter a URL" />
        <InputGroupAddon align="inline-end">
          <InputGroupButton>Copy</InputGroupButton>
        </InputGroupAddon>
      </InputGroup>
    ),
  },
  {
    id: "input-group-text",
    component: "input-group",
    title: "Input group / text addon",
    render: () => (
      <InputGroup data-parity-root className="w-72">
        <InputGroupAddon>
          <InputGroupText>https://</InputGroupText>
        </InputGroupAddon>
        <InputGroupInput placeholder="example.com" />
      </InputGroup>
    ),
  },
  {
    id: "input-group-textarea",
    component: "input-group",
    title: "Input group / textarea",
    render: () => (
      <InputGroup data-parity-root className="w-72">
        <InputGroupTextarea placeholder="Write a note" />
        <InputGroupAddon align="block-end">
          <InputGroupButton>
            <SendIcon />
          </InputGroupButton>
        </InputGroupAddon>
      </InputGroup>
    ),
  },

  /* ---------------------------------------------------------------- input-otp */
  {
    id: "input-otp-default",
    component: "input-otp",
    title: "Input OTP / six slots",
    render: () => (
      <InputOTP data-parity-root maxLength={6} value="123456" onChange={noop}>
        <InputOTPGroup>
          <InputOTPSlot index={0} />
          <InputOTPSlot index={1} />
          <InputOTPSlot index={2} />
          <InputOTPSlot index={3} />
          <InputOTPSlot index={4} />
          <InputOTPSlot index={5} />
        </InputOTPGroup>
      </InputOTP>
    ),
  },
  {
    id: "input-otp-separator",
    component: "input-otp",
    title: "Input OTP / grouped with separator",
    render: () => (
      <InputOTP data-parity-root maxLength={6} value="1234" onChange={noop}>
        <InputOTPGroup>
          <InputOTPSlot index={0} />
          <InputOTPSlot index={1} />
          <InputOTPSlot index={2} />
        </InputOTPGroup>
        <InputOTPSeparator />
        <InputOTPGroup>
          <InputOTPSlot index={3} />
          <InputOTPSlot index={4} />
          <InputOTPSlot index={5} />
        </InputOTPGroup>
      </InputOTP>
    ),
  },

  /* -------------------------------------------------------------------- input */
  {
    id: "input-default",
    component: "input",
    title: "Input / with value",
    render: () => (
      <Input data-parity-root className="w-72" defaultValue="Ada Lovelace" />
    ),
  },
  {
    id: "input-placeholder",
    component: "input",
    title: "Input / placeholder",
    render: () => (
      <Input data-parity-root className="w-72" placeholder="Email address" />
    ),
  },
  {
    id: "input-disabled",
    component: "input",
    title: "Input / disabled",
    render: () => (
      <Input data-parity-root className="w-72" disabled defaultValue="Locked" />
    ),
  },
  {
    id: "input-invalid",
    component: "input",
    title: "Input / invalid",
    render: () => (
      <Input data-parity-root className="w-72" aria-invalid defaultValue="nope" />
    ),
  },

  /* --------------------------------------------------------------------- item */
  {
    id: "item-default",
    component: "item",
    title: "Item / default",
    render: () => (
      <Item data-parity-root className="w-80">
        <ItemMedia variant="icon">
          <FolderIcon />
        </ItemMedia>
        <ItemContent>
          <ItemTitle>Documents</ItemTitle>
          <ItemDescription>12 files</ItemDescription>
        </ItemContent>
        <ItemActions>
          <Button size="icon-sm" variant="ghost">
            <ArrowRightIcon />
          </Button>
        </ItemActions>
      </Item>
    ),
  },
  {
    id: "item-outline",
    component: "item",
    title: "Item / outline",
    render: () => (
      <Item data-parity-root variant="outline" className="w-80">
        <ItemMedia variant="icon">
          <FolderIcon />
        </ItemMedia>
        <ItemContent>
          <ItemTitle>Documents</ItemTitle>
          <ItemDescription>12 files</ItemDescription>
        </ItemContent>
      </Item>
    ),
  },
  {
    id: "item-muted",
    component: "item",
    title: "Item / muted",
    render: () => (
      <Item data-parity-root variant="muted" className="w-80">
        <ItemContent>
          <ItemTitle>Documents</ItemTitle>
          <ItemDescription>12 files</ItemDescription>
        </ItemContent>
      </Item>
    ),
  },
  {
    id: "item-xs",
    component: "item",
    title: "Item / size xs",
    render: () => (
      <Item data-parity-root size="xs" variant="outline" className="w-80">
        <ItemContent>
          <ItemTitle>Documents</ItemTitle>
          <ItemDescription>12 files</ItemDescription>
        </ItemContent>
      </Item>
    ),
  },

  /* ---------------------------------------------------------------------- kbd */
  {
    id: "kbd-default",
    component: "kbd",
    title: "Kbd / single key",
    render: () => <Kbd data-parity-root>K</Kbd>,
  },
  {
    id: "kbd-group",
    component: "kbd",
    title: "Kbd / group",
    render: () => (
      <KbdGroup data-parity-root>
        <Kbd>Ctrl</Kbd>
        <Kbd>Shift</Kbd>
        <Kbd>P</Kbd>
      </KbdGroup>
    ),
  },

  /* -------------------------------------------------------------------- label */
  {
    id: "label-default",
    component: "label",
    title: "Label / default",
    render: () => <Label data-parity-root>Email address</Label>,
  },

  /* ------------------------------------------------------------------- marker */
  {
    id: "marker-default",
    component: "marker",
    title: "Marker / default",
    render: () => (
      <Marker data-parity-root className="w-72">
        <MarkerIcon>
          <CheckIcon />
        </MarkerIcon>
        <MarkerContent>Deployed to production</MarkerContent>
      </Marker>
    ),
  },
  {
    id: "marker-separator",
    component: "marker",
    title: "Marker / separator",
    render: () => (
      <Marker data-parity-root variant="separator" className="w-72">
        <MarkerContent>Today</MarkerContent>
      </Marker>
    ),
  },
  {
    id: "marker-border",
    component: "marker",
    title: "Marker / border",
    render: () => (
      <Marker data-parity-root variant="border" className="w-72">
        <MarkerContent>Older messages</MarkerContent>
      </Marker>
    ),
  },

  /* ------------------------------------------------------------------ menubar */
  {
    id: "menubar-closed",
    component: "menubar",
    title: "Menubar / closed",
    render: () => (
      <Menubar data-parity-root>
        <MenubarMenu>
          <MenubarTrigger>File</MenubarTrigger>
        </MenubarMenu>
        <MenubarMenu>
          <MenubarTrigger>Edit</MenubarTrigger>
        </MenubarMenu>
        <MenubarMenu>
          <MenubarTrigger>View</MenubarTrigger>
        </MenubarMenu>
      </Menubar>
    ),
  },
  {
    id: "menubar-open",
    component: "menubar",
    title: "Menubar / open menu",
    render: () => (
      <Menubar>
        <MenubarMenu defaultOpen>
          <MenubarTrigger>File</MenubarTrigger>
          <MenubarContent data-parity-root>
            <MenubarItem>
              New tab
              <MenubarShortcut>T</MenubarShortcut>
            </MenubarItem>
            <MenubarItem>New window</MenubarItem>
            <MenubarSeparator />
            <MenubarItem>Print</MenubarItem>
          </MenubarContent>
        </MenubarMenu>
        <MenubarMenu>
          <MenubarTrigger>Edit</MenubarTrigger>
        </MenubarMenu>
      </Menubar>
    ),
  },

  /* ---------------------------------------------------------- message-scroller */
  {
    id: "message-scroller-default",
    component: "message-scroller",
    title: "Message scroller / three items",
    render: () => (
      <MessageScrollerProvider>
        <MessageScroller data-parity-root className="h-48 w-80 border">
          <MessageScrollerViewport>
            <MessageScrollerContent>
              <MessageScrollerItem>First message</MessageScrollerItem>
              <MessageScrollerItem>Second message</MessageScrollerItem>
              <MessageScrollerItem>Third message</MessageScrollerItem>
            </MessageScrollerContent>
          </MessageScrollerViewport>
        </MessageScroller>
      </MessageScrollerProvider>
    ),
  },

  /* ------------------------------------------------------------------ message */
  {
    id: "message-start",
    component: "message",
    title: "Message / start aligned",
    render: () => (
      <Message data-parity-root className="w-80">
        <MessageAvatar>AL</MessageAvatar>
        <MessageContent>
          <MessageHeader>Ada</MessageHeader>
          <Bubble variant="muted">
            <BubbleContent>Patch looks good.</BubbleContent>
          </Bubble>
        </MessageContent>
      </Message>
    ),
  },
  {
    id: "message-end",
    component: "message",
    title: "Message / end aligned",
    render: () => (
      <Message data-parity-root align="end" className="w-80">
        <MessageContent>
          <Bubble>
            <BubbleContent>Thanks, merging now.</BubbleContent>
          </Bubble>
          <MessageFooter>Sent</MessageFooter>
        </MessageContent>
      </Message>
    ),
  },

  /* ------------------------------------------------------------ native-select */
  {
    id: "native-select-default",
    component: "native-select",
    title: "Native select / default",
    render: () => (
      <NativeSelect data-parity-root defaultValue="banana">
        <NativeSelectOption value="apple">Apple</NativeSelectOption>
        <NativeSelectOption value="banana">Banana</NativeSelectOption>
        <NativeSelectOption value="cherry">Cherry</NativeSelectOption>
      </NativeSelect>
    ),
  },
  {
    id: "native-select-sm",
    component: "native-select",
    title: "Native select / small with groups",
    render: () => (
      <NativeSelect data-parity-root size="sm" defaultValue="apple">
        <NativeSelectOptGroup label="Fruit">
          <NativeSelectOption value="apple">Apple</NativeSelectOption>
          <NativeSelectOption value="banana">Banana</NativeSelectOption>
        </NativeSelectOptGroup>
      </NativeSelect>
    ),
  },

  /* --------------------------------------------------------- navigation-menu */
  {
    id: "navigation-menu-closed",
    component: "navigation-menu",
    title: "Navigation menu / closed",
    render: () => (
      <NavigationMenu data-parity-root>
        <NavigationMenuList>
          <NavigationMenuItem value="products">
            <NavigationMenuTrigger>Products</NavigationMenuTrigger>
          </NavigationMenuItem>
          <NavigationMenuItem value="company">
            <NavigationMenuTrigger>Company</NavigationMenuTrigger>
          </NavigationMenuItem>
        </NavigationMenuList>
      </NavigationMenu>
    ),
  },
  {
    id: "navigation-menu-open",
    component: "navigation-menu",
    title: "Navigation menu / open content",
    render: () => (
      <NavigationMenu defaultValue="products">
        <NavigationMenuList>
          <NavigationMenuItem value="products">
            <NavigationMenuTrigger>Products</NavigationMenuTrigger>
            <NavigationMenuContent data-parity-root className="w-56">
              <NavigationMenuLink href="#">
                <RocketIcon />
                Launch
              </NavigationMenuLink>
              <NavigationMenuLink href="#">
                <StarIcon />
                Favourites
              </NavigationMenuLink>
            </NavigationMenuContent>
          </NavigationMenuItem>
        </NavigationMenuList>
      </NavigationMenu>
    ),
  },

  /* --------------------------------------------------------------- pagination */
  {
    id: "pagination-default",
    component: "pagination",
    title: "Pagination / default",
    render: () => (
      <Pagination data-parity-root>
        <PaginationContent>
          <PaginationItem>
            <PaginationPrevious href="#" />
          </PaginationItem>
          <PaginationItem>
            <PaginationLink href="#">1</PaginationLink>
          </PaginationItem>
          <PaginationItem>
            <PaginationLink href="#" isActive>
              2
            </PaginationLink>
          </PaginationItem>
          <PaginationItem>
            <PaginationLink href="#">3</PaginationLink>
          </PaginationItem>
          <PaginationItem>
            <PaginationEllipsis />
          </PaginationItem>
          <PaginationItem>
            <PaginationNext href="#" />
          </PaginationItem>
        </PaginationContent>
      </Pagination>
    ),
  },

  /* ------------------------------------------------------------------ popover */
  {
    id: "popover-default",
    component: "popover",
    title: "Popover / open",
    render: () => (
      <Popover defaultOpen>
        <PopoverTrigger render={<Button variant="outline" />}>
          Open
        </PopoverTrigger>
        <PopoverContent data-parity-root>
          Dimensions are applied on save.
        </PopoverContent>
      </Popover>
    ),
  },
  {
    id: "popover-header",
    component: "popover",
    title: "Popover / header and description",
    render: () => (
      <Popover defaultOpen>
        <PopoverTrigger render={<Button variant="outline" />}>
          Open
        </PopoverTrigger>
        <PopoverContent data-parity-root>
          <PopoverHeader>
            <PopoverTitle>Dimensions</PopoverTitle>
            <PopoverDescription>Set the width and height.</PopoverDescription>
          </PopoverHeader>
          <Input placeholder="Width" />
        </PopoverContent>
      </Popover>
    ),
  },

  /* ----------------------------------------------------------------- progress */
  {
    id: "progress-default",
    component: "progress",
    title: "Progress / 60 percent",
    render: () => <Progress data-parity-root value={60} className="w-72" />,
  },
  {
    id: "progress-label",
    component: "progress",
    title: "Progress / label and value",
    render: () => (
      <Progress data-parity-root value={35} className="w-72">
        <ProgressLabel>Uploading</ProgressLabel>
        <ProgressValue />
      </Progress>
    ),
  },

  /* ------------------------------------------------------------ questionnaire */
  {
    id: "questionnaire-choices",
    component: "questionnaire",
    title: "Questionnaire / choices",
    render: () => (
      <Questionnaire
        data-parity-root
        className="w-96"
        defaultItem="plan"
        items={[
          {
            name: "plan",
            choices: [{ value: "free" }, { value: "pro" }, { value: "team" }],
          },
        ]}
      >
        <QuestionnaireProgress />
        <QuestionnaireItem name="plan">
          <QuestionnaireTitle>Which plan fits best?</QuestionnaireTitle>
          <QuestionnaireDescription>
            You can change it later.
          </QuestionnaireDescription>
          <QuestionnaireChoices>
            <QuestionnaireChoice value="free" defaultChecked>
              Free
              <QuestionnaireChoiceDescription>
                One project
              </QuestionnaireChoiceDescription>
            </QuestionnaireChoice>
            <QuestionnaireChoice value="pro">
              Pro
              <QuestionnaireChoiceDescription>
                Ten projects
              </QuestionnaireChoiceDescription>
            </QuestionnaireChoice>
            <QuestionnaireChoice value="team">Team</QuestionnaireChoice>
          </QuestionnaireChoices>
        </QuestionnaireItem>
        <QuestionnaireActions>
          <QuestionnairePrevious />
          <QuestionnaireNext />
        </QuestionnaireActions>
      </Questionnaire>
    ),
  },
  {
    id: "questionnaire-input",
    component: "questionnaire",
    title: "Questionnaire / text input",
    render: () => (
      <Questionnaire
        data-parity-root
        className="w-96"
        defaultItem="name"
        items={[{ name: "name", required: true }]}
      >
        <QuestionnaireItem name="name" required>
          <QuestionnaireTitle>What is your name?</QuestionnaireTitle>
          <QuestionnaireInput placeholder="Ada Lovelace" />
        </QuestionnaireItem>
        <QuestionnaireActions>
          <QuestionnairePrevious />
          <QuestionnaireNext />
        </QuestionnaireActions>
      </Questionnaire>
    ),
  },

  /* -------------------------------------------------------------- radio-group */
  {
    id: "radio-group-default",
    component: "radio-group",
    title: "Radio group / default",
    render: () => (
      <RadioGroup data-parity-root defaultValue="pro" className="w-72">
        <Field orientation="horizontal">
          <RadioGroupItem value="free" id="rg-free" />
          <FieldLabel htmlFor="rg-free">Free</FieldLabel>
        </Field>
        <Field orientation="horizontal">
          <RadioGroupItem value="pro" id="rg-pro" />
          <FieldLabel htmlFor="rg-pro">Pro</FieldLabel>
        </Field>
      </RadioGroup>
    ),
  },
  {
    id: "radio-group-disabled",
    component: "radio-group",
    title: "Radio group / disabled",
    render: () => (
      <RadioGroup data-parity-root defaultValue="pro" disabled className="w-72">
        <Field orientation="horizontal">
          <RadioGroupItem value="free" id="rgd-free" />
          <FieldLabel htmlFor="rgd-free">Free</FieldLabel>
        </Field>
        <Field orientation="horizontal">
          <RadioGroupItem value="pro" id="rgd-pro" />
          <FieldLabel htmlFor="rgd-pro">Pro</FieldLabel>
        </Field>
      </RadioGroup>
    ),
  },

  /* ---------------------------------------------------------------- resizable */
  {
    id: "resizable-horizontal",
    component: "resizable",
    title: "Resizable / horizontal",
    render: () => (
      <ResizablePanelGroup
        data-parity-root
        orientation="horizontal"
        className="h-40 w-96 rounded-lg border"
      >
        <ResizablePanel defaultSize="50%" className="p-2 text-sm">
          Left
        </ResizablePanel>
        <ResizableHandle withHandle />
        <ResizablePanel defaultSize="50%" className="p-2 text-sm">
          Right
        </ResizablePanel>
      </ResizablePanelGroup>
    ),
  },
  {
    id: "resizable-vertical",
    component: "resizable",
    title: "Resizable / vertical",
    render: () => (
      <ResizablePanelGroup
        data-parity-root
        orientation="vertical"
        className="h-40 w-96 rounded-lg border"
      >
        <ResizablePanel defaultSize="50%" className="p-2 text-sm">
          Top
        </ResizablePanel>
        <ResizableHandle />
        <ResizablePanel defaultSize="50%" className="p-2 text-sm">
          Bottom
        </ResizablePanel>
      </ResizablePanelGroup>
    ),
  },

  /* --------------------------------------------------------------- scroll-area */
  {
    id: "scroll-area-default",
    component: "scroll-area",
    title: "Scroll area / vertical",
    render: () => (
      <ScrollArea data-parity-root className="h-40 w-64 rounded-lg border">
        <div className="flex flex-col gap-2 p-3 text-sm">
          <div>Row one</div>
          <div>Row two</div>
          <div>Row three</div>
          <div>Row four</div>
          <div>Row five</div>
          <div>Row six</div>
          <div>Row seven</div>
          <div>Row eight</div>
          <div>Row nine</div>
          <div>Row ten</div>
        </div>
      </ScrollArea>
    ),
  },

  /* ------------------------------------------------------------------- select */
  {
    id: "select-trigger",
    component: "select",
    title: "Select / closed trigger",
    render: () => (
      <Select
        defaultValue="banana"
        items={[
          { label: "Apple", value: "apple" },
          { label: "Banana", value: "banana" },
          { label: "Cherry", value: "cherry" },
        ]}
      >
        <SelectTrigger data-parity-root className="w-56">
          <SelectValue />
        </SelectTrigger>
      </Select>
    ),
  },
  {
    id: "select-trigger-sm",
    component: "select",
    title: "Select / small trigger with placeholder",
    render: () => (
      <Select>
        <SelectTrigger data-parity-root size="sm" className="w-56">
          <SelectValue placeholder="Pick a fruit" />
        </SelectTrigger>
      </Select>
    ),
  },
  {
    id: "select-open",
    component: "select",
    title: "Select / open list",
    render: () => (
      <Select
        defaultOpen
        defaultValue="banana"
        items={[
          { label: "Apple", value: "apple" },
          { label: "Banana", value: "banana" },
          { label: "Cherry", value: "cherry" },
        ]}
      >
        <SelectTrigger className="w-56">
          <SelectValue />
        </SelectTrigger>
        <SelectContent data-parity-root>
          <SelectGroup>
            <SelectLabel>Fruit</SelectLabel>
            <SelectItem value="apple">Apple</SelectItem>
            <SelectItem value="banana">Banana</SelectItem>
            <SelectSeparator />
            <SelectItem value="cherry">Cherry</SelectItem>
          </SelectGroup>
        </SelectContent>
      </Select>
    ),
  },

  /* ---------------------------------------------------------------- separator */
  {
    id: "separator-horizontal",
    component: "separator",
    title: "Separator / horizontal",
    render: () => <Separator data-parity-root className="w-64" />,
  },
  {
    id: "separator-vertical",
    component: "separator",
    title: "Separator / vertical",
    render: () => (
      <Separator data-parity-root orientation="vertical" className="h-16" />
    ),
  },

  /* -------------------------------------------------------------------- sheet */
  {
    id: "sheet-right",
    component: "sheet",
    title: "Sheet / right",
    render: () => (
      <Sheet defaultOpen>
        <SheetContent data-parity-root side="right">
          <SheetHeader>
            <SheetTitle>Edit profile</SheetTitle>
            <SheetDescription>Make changes and save.</SheetDescription>
          </SheetHeader>
          <SheetFooter>
            <Button>Save</Button>
          </SheetFooter>
        </SheetContent>
      </Sheet>
    ),
  },
  {
    id: "sheet-bottom",
    component: "sheet",
    title: "Sheet / bottom",
    render: () => (
      <Sheet defaultOpen>
        <SheetContent data-parity-root side="bottom">
          <SheetHeader>
            <SheetTitle>Edit profile</SheetTitle>
            <SheetDescription>Make changes and save.</SheetDescription>
          </SheetHeader>
          <SheetFooter>
            <Button>Save</Button>
          </SheetFooter>
        </SheetContent>
      </Sheet>
    ),
  },

  /* ------------------------------------------------------------------ sidebar */
  {
    id: "sidebar-default",
    component: "sidebar",
    title: "Sidebar / header, content, footer",
    render: () => (
      <SidebarProvider>
        <Sidebar data-parity-root collapsible="none" className="h-96 border">
          <SidebarHeader>
            <SidebarMenu>
              <SidebarMenuItem>
                <SidebarMenuButton size="lg">
                  <HouseIcon />
                  Acme Inc
                </SidebarMenuButton>
              </SidebarMenuItem>
            </SidebarMenu>
          </SidebarHeader>
          <SidebarSeparator />
          <SidebarContent>
            <SidebarGroup>
              <SidebarGroupLabel>Platform</SidebarGroupLabel>
              <SidebarGroupContent>
                <SidebarMenu>
                  <SidebarMenuItem>
                    <SidebarMenuButton isActive>
                      <InboxIcon />
                      Inbox
                    </SidebarMenuButton>
                    <SidebarMenuBadge>4</SidebarMenuBadge>
                  </SidebarMenuItem>
                  <SidebarMenuItem>
                    <SidebarMenuButton>
                      <CalendarIcon />
                      Calendar
                    </SidebarMenuButton>
                  </SidebarMenuItem>
                </SidebarMenu>
              </SidebarGroupContent>
            </SidebarGroup>
          </SidebarContent>
          <SidebarFooter>
            <SidebarMenu>
              <SidebarMenuItem>
                <SidebarMenuButton>
                  <SettingsIcon />
                  Settings
                </SidebarMenuButton>
              </SidebarMenuItem>
            </SidebarMenu>
          </SidebarFooter>
        </Sidebar>
      </SidebarProvider>
    ),
  },
  {
    id: "sidebar-submenu",
    component: "sidebar",
    title: "Sidebar / submenu",
    render: () => (
      <SidebarProvider>
        <Sidebar data-parity-root collapsible="none" className="h-72 border">
          <SidebarContent>
            <SidebarGroup>
              <SidebarGroupLabel>Project</SidebarGroupLabel>
              <SidebarMenu>
                <SidebarMenuItem>
                  <SidebarMenuButton>
                    <FolderIcon />
                    src
                  </SidebarMenuButton>
                  <SidebarMenuSub>
                    <SidebarMenuSubItem>
                      <SidebarMenuSubButton href="#">
                        index.ts
                      </SidebarMenuSubButton>
                    </SidebarMenuSubItem>
                    <SidebarMenuSubItem>
                      <SidebarMenuSubButton href="#" isActive>
                        app.tsx
                      </SidebarMenuSubButton>
                    </SidebarMenuSubItem>
                  </SidebarMenuSub>
                </SidebarMenuItem>
              </SidebarMenu>
            </SidebarGroup>
          </SidebarContent>
        </Sidebar>
      </SidebarProvider>
    ),
  },

  /* ----------------------------------------------------------------- skeleton */
  {
    id: "skeleton-default",
    component: "skeleton",
    title: "Skeleton / text line",
    render: () => <Skeleton data-parity-root className="h-4 w-64" />,
  },
  {
    id: "skeleton-circle",
    component: "skeleton",
    title: "Skeleton / circle",
    render: () => (
      <Skeleton data-parity-root className="size-10 rounded-full" />
    ),
  },

  /* ------------------------------------------------------------------- slider */
  {
    id: "slider-default",
    component: "slider",
    title: "Slider / single value",
    render: () => (
      <Slider data-parity-root defaultValue={50} className="w-72" />
    ),
  },
  {
    id: "slider-range",
    component: "slider",
    title: "Slider / range",
    render: () => (
      <Slider data-parity-root defaultValue={[25, 75]} className="w-72" />
    ),
  },
  {
    id: "slider-vertical",
    component: "slider",
    title: "Slider / vertical",
    render: () => (
      <Slider
        data-parity-root
        orientation="vertical"
        defaultValue={40}
        className="h-48"
      />
    ),
  },

  /* ------------------------------------------------------------------ spinner */
  {
    id: "spinner-default",
    component: "spinner",
    title: "Spinner / default",
    render: () => <Spinner data-parity-root />,
  },
  {
    id: "spinner-lg",
    component: "spinner",
    title: "Spinner / large",
    render: () => <Spinner data-parity-root className="size-8" />,
  },

  /* ------------------------------------------------------------------- switch */
  {
    id: "switch-off",
    component: "switch",
    title: "Switch / off",
    render: () => <Switch data-parity-root />,
  },
  {
    id: "switch-on",
    component: "switch",
    title: "Switch / on",
    render: () => <Switch data-parity-root defaultChecked />,
  },
  {
    id: "switch-sm",
    component: "switch",
    title: "Switch / small on",
    render: () => <Switch data-parity-root size="sm" defaultChecked />,
  },
  {
    id: "switch-disabled",
    component: "switch",
    title: "Switch / disabled",
    render: () => <Switch data-parity-root disabled defaultChecked />,
  },

  /* -------------------------------------------------------------------- table */
  {
    id: "table-default",
    component: "table",
    title: "Table / default",
    render: () => (
      <Table data-parity-root className="w-[480px]">
        <TableHeader>
          <TableRow>
            <TableHead>Invoice</TableHead>
            <TableHead>Status</TableHead>
            <TableHead className="text-right">Amount</TableHead>
          </TableRow>
        </TableHeader>
        <TableBody>
          <TableRow>
            <TableCell>INV001</TableCell>
            <TableCell>Paid</TableCell>
            <TableCell className="text-right">250.00</TableCell>
          </TableRow>
          <TableRow>
            <TableCell>INV002</TableCell>
            <TableCell>Pending</TableCell>
            <TableCell className="text-right">150.00</TableCell>
          </TableRow>
          <TableRow>
            <TableCell>INV003</TableCell>
            <TableCell>Unpaid</TableCell>
            <TableCell className="text-right">350.00</TableCell>
          </TableRow>
        </TableBody>
      </Table>
    ),
  },
  {
    id: "table-footer",
    component: "table",
    title: "Table / caption and footer",
    render: () => (
      <Table data-parity-root className="w-[480px]">
        <TableCaption>A list of recent invoices.</TableCaption>
        <TableHeader>
          <TableRow>
            <TableHead>Invoice</TableHead>
            <TableHead className="text-right">Amount</TableHead>
          </TableRow>
        </TableHeader>
        <TableBody>
          <TableRow>
            <TableCell>INV001</TableCell>
            <TableCell className="text-right">250.00</TableCell>
          </TableRow>
          <TableRow data-state="selected">
            <TableCell>INV002</TableCell>
            <TableCell className="text-right">150.00</TableCell>
          </TableRow>
        </TableBody>
        <TableFooter>
          <TableRow>
            <TableCell>Total</TableCell>
            <TableCell className="text-right">400.00</TableCell>
          </TableRow>
        </TableFooter>
      </Table>
    ),
  },

  /* --------------------------------------------------------------------- tabs */
  {
    id: "tabs-default",
    component: "tabs",
    title: "Tabs / default",
    render: () => (
      <Tabs data-parity-root defaultValue="account" className="w-96">
        <TabsList>
          <TabsTrigger value="account">Account</TabsTrigger>
          <TabsTrigger value="password">Password</TabsTrigger>
        </TabsList>
        <TabsContent value="account">Account settings.</TabsContent>
        <TabsContent value="password">Password settings.</TabsContent>
      </Tabs>
    ),
  },
  {
    id: "tabs-line",
    component: "tabs",
    title: "Tabs / line variant",
    render: () => (
      <Tabs data-parity-root defaultValue="account" className="w-96">
        <TabsList variant="line">
          <TabsTrigger value="account">Account</TabsTrigger>
          <TabsTrigger value="password">Password</TabsTrigger>
        </TabsList>
        <TabsContent value="account">Account settings.</TabsContent>
        <TabsContent value="password">Password settings.</TabsContent>
      </Tabs>
    ),
  },
  {
    id: "tabs-vertical",
    component: "tabs",
    title: "Tabs / vertical",
    render: () => (
      <Tabs
        data-parity-root
        orientation="vertical"
        defaultValue="account"
        className="w-96"
      >
        <TabsList>
          <TabsTrigger value="account">Account</TabsTrigger>
          <TabsTrigger value="password">Password</TabsTrigger>
        </TabsList>
        <TabsContent value="account">Account settings.</TabsContent>
        <TabsContent value="password">Password settings.</TabsContent>
      </Tabs>
    ),
  },

  /* ----------------------------------------------------------------- textarea */
  {
    id: "textarea-default",
    component: "textarea",
    title: "Textarea / placeholder",
    render: () => (
      <Textarea data-parity-root className="w-72" placeholder="Type a note" />
    ),
  },
  {
    id: "textarea-disabled",
    component: "textarea",
    title: "Textarea / disabled",
    render: () => (
      <Textarea
        data-parity-root
        className="w-72"
        disabled
        defaultValue="Locked note"
      />
    ),
  },

  /* -------------------------------------------------------------------- toast */
  {
    id: "toast-default",
    component: "toast",
    title: "Toast / title and description",
    render: () => (
      <ToastCase title="Saved" description="Your changes are stored." />
    ),
  },
  {
    id: "toast-action",
    component: "toast",
    title: "Toast / with action",
    render: () => (
      <ToastCase
        title="Item deleted"
        description="The row was removed."
        withAction
      />
    ),
  },

  /* ------------------------------------------------------------- toggle-group */
  {
    id: "toggle-group-default",
    component: "toggle-group",
    title: "Toggle group / default",
    render: () => (
      <ToggleGroup data-parity-root defaultValue={["bold"]}>
        <ToggleGroupItem value="bold">
          <BoldIcon />
        </ToggleGroupItem>
        <ToggleGroupItem value="italic">
          <ItalicIcon />
        </ToggleGroupItem>
        <ToggleGroupItem value="underline">
          <UnderlineIcon />
        </ToggleGroupItem>
      </ToggleGroup>
    ),
  },
  {
    id: "toggle-group-outline",
    component: "toggle-group",
    title: "Toggle group / outline, joined",
    render: () => (
      <ToggleGroup
        data-parity-root
        variant="outline"
        spacing={0}
        defaultValue={["left"]}
      >
        <ToggleGroupItem value="left">
          <AlignLeftIcon />
        </ToggleGroupItem>
        <ToggleGroupItem value="center">
          <AlignCenterIcon />
        </ToggleGroupItem>
      </ToggleGroup>
    ),
  },
  {
    id: "toggle-group-vertical",
    component: "toggle-group",
    title: "Toggle group / vertical",
    render: () => (
      <ToggleGroup
        data-parity-root
        orientation="vertical"
        defaultValue={["bold"]}
      >
        <ToggleGroupItem value="bold">
          <BoldIcon />
        </ToggleGroupItem>
        <ToggleGroupItem value="italic">
          <ItalicIcon />
        </ToggleGroupItem>
      </ToggleGroup>
    ),
  },

  /* ------------------------------------------------------------------- toggle */
  {
    id: "toggle-default",
    component: "toggle",
    title: "Toggle / default",
    render: () => (
      <Toggle data-parity-root>
        <BoldIcon />
      </Toggle>
    ),
  },
  {
    id: "toggle-pressed",
    component: "toggle",
    title: "Toggle / pressed",
    render: () => (
      <Toggle data-parity-root defaultPressed>
        <BoldIcon />
      </Toggle>
    ),
  },
  {
    id: "toggle-outline",
    component: "toggle",
    title: "Toggle / outline",
    render: () => (
      <Toggle data-parity-root variant="outline">
        <SunIcon />
      </Toggle>
    ),
  },
  {
    id: "toggle-sm",
    component: "toggle",
    title: "Toggle / small with text",
    render: () => (
      <Toggle data-parity-root size="sm">
        Bold
      </Toggle>
    ),
  },
  {
    id: "toggle-lg",
    component: "toggle",
    title: "Toggle / large with text",
    render: () => (
      <Toggle data-parity-root size="lg" variant="outline">
        Bold
      </Toggle>
    ),
  },

  /* ------------------------------------------------------------------ tooltip */
  {
    id: "tooltip-default",
    component: "tooltip",
    title: "Tooltip / open",
    render: () => (
      <TooltipProvider delay={0}>
        <Tooltip defaultOpen>
          <TooltipTrigger render={<Button variant="outline" />}>
            Hover
          </TooltipTrigger>
          <TooltipContent data-parity-root>Add to library</TooltipContent>
        </Tooltip>
      </TooltipProvider>
    ),
  },
  {
    id: "tooltip-kbd",
    component: "tooltip",
    title: "Tooltip / with kbd",
    render: () => (
      <TooltipProvider delay={0}>
        <Tooltip defaultOpen>
          <TooltipTrigger render={<Button variant="outline" />}>
            Hover
          </TooltipTrigger>
          <TooltipContent data-parity-root>
            Save
            <Kbd>S</Kbd>
          </TooltipContent>
        </Tooltip>
      </TooltipProvider>
    ),
  },
]

function noop() {
  /* controlled inputs in a static snapshot never change */
}

export const CASES_BY_ID: Record<string, Case> = Object.fromEntries(
  CASES.map((entry) => [entry.id, entry])
)

export function getCase(id: string | undefined): Case | undefined {
  return id ? CASES_BY_ID[id] : undefined
}

export function caseIndex(): Array<Pick<Case, "id" | "component" | "title">> {
  return CASES.map(({ id, component, title }) => ({ id, component, title }))
}
