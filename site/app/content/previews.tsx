import type { ReactNode } from "react";
import { lazy, Suspense, useState } from "react";
import {
  AlignCenterIcon,
  AlignLeftIcon,
  BadgeCheckIcon,
  BellIcon,
  BoldIcon,
  ChevronDownIcon,
  DownloadIcon,
  FileTextIcon,
  FolderIcon,
  InboxIcon,
  ItalicIcon,
  SearchIcon,
  SettingsIcon,
  TerminalIcon,
  TrashIcon,
  UnderlineIcon,
} from "lucide-react";

import {
  Accordion,
  AccordionContent,
  AccordionItem,
  AccordionTrigger,
} from "~/components/ui/accordion";
import { Alert, AlertDescription, AlertTitle } from "~/components/ui/alert";
import {
  AlertDialog,
  AlertDialogAction,
  AlertDialogCancel,
  AlertDialogContent,
  AlertDialogDescription,
  AlertDialogFooter,
  AlertDialogHeader,
  AlertDialogTitle,
  AlertDialogTrigger,
} from "~/components/ui/alert-dialog";
import { AspectRatio } from "~/components/ui/aspect-ratio";
import {
  Attachment,
  AttachmentContent,
  AttachmentDescription,
  AttachmentMedia,
  AttachmentTitle,
} from "~/components/ui/attachment";
import {
  Avatar,
  AvatarFallback,
  AvatarGroup,
  AvatarGroupCount,
} from "~/components/ui/avatar";
import { Badge } from "~/components/ui/badge";
import {
  Breadcrumb,
  BreadcrumbEllipsis,
  BreadcrumbItem,
  BreadcrumbLink,
  BreadcrumbList,
  BreadcrumbPage,
  BreadcrumbSeparator,
} from "~/components/ui/breadcrumb";
import { Bubble, BubbleContent } from "~/components/ui/bubble";
import { Button } from "~/components/ui/button";
import { ButtonGroup } from "~/components/ui/button-group";
import {
  Card,
  CardContent,
  CardDescription,
  CardFooter,
  CardHeader,
  CardTitle,
} from "~/components/ui/card";
import {
  Carousel,
  CarouselContent,
  CarouselItem,
  CarouselNext,
  CarouselPrevious,
} from "~/components/ui/carousel";
import { Checkbox } from "~/components/ui/checkbox";
import {
  Collapsible,
  CollapsibleContent,
  CollapsibleTrigger,
} from "~/components/ui/collapsible";
import {
  Command,
  CommandGroup,
  CommandInput,
  CommandItem,
  CommandList,
  CommandShortcut,
} from "~/components/ui/command";
import {
  ContextMenu,
  ContextMenuContent,
  ContextMenuItem,
  ContextMenuSeparator,
  ContextMenuShortcut,
  ContextMenuTrigger,
} from "~/components/ui/context-menu";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogHeader,
  DialogTitle,
  DialogTrigger,
} from "~/components/ui/dialog";
import { DirectionProvider } from "~/components/ui/direction";
import {
  Drawer,
  DrawerContent,
  DrawerDescription,
  DrawerHeader,
  DrawerTitle,
  DrawerTrigger,
} from "~/components/ui/drawer";
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuGroup,
  DropdownMenuItem,
  DropdownMenuLabel,
  DropdownMenuSeparator,
  DropdownMenuTrigger,
} from "~/components/ui/dropdown-menu";
import {
  Empty,
  EmptyDescription,
  EmptyHeader,
  EmptyMedia,
  EmptyTitle,
} from "~/components/ui/empty";
import {
  Field,
  FieldDescription,
  FieldLabel,
} from "~/components/ui/field";
import {
  HoverCard,
  HoverCardContent,
  HoverCardTrigger,
} from "~/components/ui/hover-card";
import { Input } from "~/components/ui/input";
import {
  InputGroup,
  InputGroupAddon,
  InputGroupInput,
} from "~/components/ui/input-group";
import {
  InputOTP,
  InputOTPGroup,
  InputOTPSeparator,
  InputOTPSlot,
} from "~/components/ui/input-otp";
import {
  Item,
  ItemActions,
  ItemContent,
  ItemDescription,
  ItemMedia,
  ItemTitle,
} from "~/components/ui/item";
import { Kbd, KbdGroup } from "~/components/ui/kbd";
import { Label } from "~/components/ui/label";
import { Marker, MarkerContent } from "~/components/ui/marker";
import {
  Menubar,
  MenubarContent,
  MenubarItem,
  MenubarMenu,
  MenubarSeparator,
  MenubarShortcut,
  MenubarTrigger,
} from "~/components/ui/menubar";
import {
  Message,
  MessageAvatar,
  MessageContent,
} from "~/components/ui/message";
import {
  MessageScroller,
  MessageScrollerContent,
  MessageScrollerItem,
  MessageScrollerProvider,
  MessageScrollerViewport,
} from "~/components/ui/message-scroller";
import {
  NativeSelect,
  NativeSelectOption,
} from "~/components/ui/native-select";
import {
  NavigationMenu,
  NavigationMenuItem,
  NavigationMenuLink,
  NavigationMenuList,
} from "~/components/ui/navigation-menu";
import {
  Pagination,
  PaginationContent,
  PaginationEllipsis,
  PaginationItem,
  PaginationLink,
  PaginationNext,
  PaginationPrevious,
} from "~/components/ui/pagination";
import {
  Popover,
  PopoverContent,
  PopoverDescription,
  PopoverHeader,
  PopoverTitle,
  PopoverTrigger,
} from "~/components/ui/popover";
import { Progress } from "~/components/ui/progress";
import { RadioGroup, RadioGroupItem } from "~/components/ui/radio-group";
import {
  ResizableHandle,
  ResizablePanel,
  ResizablePanelGroup,
} from "~/components/ui/resizable";
import { ScrollArea } from "~/components/ui/scroll-area";
import {
  Select,
  SelectContent,
  SelectGroup,
  SelectItem,
  SelectLabel,
  SelectTrigger,
  SelectValue,
} from "~/components/ui/select";
import { Separator } from "~/components/ui/separator";
import {
  Sheet,
  SheetContent,
  SheetDescription,
  SheetHeader,
  SheetTitle,
  SheetTrigger,
} from "~/components/ui/sheet";
import {
  Sidebar,
  SidebarContent,
  SidebarGroup,
  SidebarGroupContent,
  SidebarGroupLabel,
  SidebarMenu,
  SidebarMenuButton,
  SidebarMenuItem,
  SidebarProvider,
} from "~/components/ui/sidebar";
import { Skeleton } from "~/components/ui/skeleton";
import { Slider } from "~/components/ui/slider";
import { Spinner } from "~/components/ui/spinner";
import { Switch } from "~/components/ui/switch";
import {
  Table,
  TableBody,
  TableCaption,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "~/components/ui/table";
import { Tabs, TabsContent, TabsList, TabsTrigger } from "~/components/ui/tabs";
import { Textarea } from "~/components/ui/textarea";
import { Toaster, toast } from "~/components/ui/toast";
import { Toggle } from "~/components/ui/toggle";
import { ToggleGroup, ToggleGroupItem } from "~/components/ui/toggle-group";
import {
  Tooltip,
  TooltipContent,
  TooltipTrigger,
} from "~/components/ui/tooltip";
const Chart = lazy(() =>
  import("~/components/chart-preview").then((m) => ({ default: m.Chart })),
);
const Calendar = lazy(() =>
  import("~/components/ui/calendar").then((m) => ({ default: m.Calendar })),
);
import { ComboboxPreview } from "~/components/combobox-preview";

/* -------------------------------------------------------------------------- */

/** A preview whose dependency is fetched on demand. */
const Deferred = ({ children }: { children: ReactNode }) => (
  <Suspense
    fallback={<div className="h-6 w-32 animate-pulse rounded bg-muted" />}
  >
    {children}
  </Suspense>
);

const Row = ({ children }: { children: ReactNode }) => (
  <div className="flex flex-wrap items-center justify-center gap-3">
    {children}
  </div>
);

const Col = ({ children }: { children: ReactNode }) => (
  <div className="flex w-full max-w-sm flex-col gap-3">{children}</div>
);

function CheckboxDemo() {
  const [on, setOn] = useState(true);
  return (
    <div className="flex items-center gap-2">
      <Checkbox checked={on} onCheckedChange={(v) => setOn(Boolean(v))} />
      <Label>Accept terms and conditions</Label>
    </div>
  );
}

function SwitchDemo() {
  const [on, setOn] = useState(true);
  return (
    <div className="flex items-center gap-2">
      <Switch checked={on} onCheckedChange={(v) => setOn(Boolean(v))} />
      <Label>Airplane mode</Label>
    </div>
  );
}

function TogglePressed() {
  const [on, setOn] = useState(false);
  return (
    <Toggle
      variant="outline"
      pressed={on}
      onPressedChange={(v) => setOn(Boolean(v))}
      aria-label="Bold"
    >
      <BoldIcon />
    </Toggle>
  );
}

function ToastDemo() {
  return (
    <Toaster>
      <Button
        variant="outline"
        onClick={() =>
          toast.add({
            title: "Saved",
            description: "Your changes are on disk.",
          })
        }
      >
        Show a toast
      </Button>
    </Toaster>
  );
}

function CollapsibleDemo() {
  return (
    <Collapsible className="w-full max-w-sm">
      <CollapsibleTrigger className="flex w-full items-center justify-between rounded-md border px-3 py-2 text-sm font-medium">
        Starred repositories
        <ChevronDownIcon className="size-4" />
      </CollapsibleTrigger>
      <CollapsibleContent className="px-3 py-2 text-sm text-muted-foreground">
        palmframe/palmy
      </CollapsibleContent>
    </Collapsible>
  );
}

/* -------------------------------------------------------------------------- */
/* The map                                                                     */
/* -------------------------------------------------------------------------- */

export const PREVIEWS: Record<string, () => ReactNode> = {
  accordion: () => (
    <Accordion className="w-full max-w-md" defaultValue={["one"]}>
      <AccordionItem value="one">
        <AccordionTrigger>Is it accessible?</AccordionTrigger>
        <AccordionContent>
          Yes. It follows the WAI-ARIA pattern.
        </AccordionContent>
      </AccordionItem>
      <AccordionItem value="two">
        <AccordionTrigger>Is it styled?</AccordionTrigger>
        <AccordionContent>
          Yes, with the same tokens the Odin side registers.
        </AccordionContent>
      </AccordionItem>
    </Accordion>
  ),

  alert: () => (
    <div className="w-full max-w-md space-y-3">
      <Alert>
        <TerminalIcon />
        <AlertTitle>Heads up</AlertTitle>
        <AlertDescription>
          You can add components to your app using the CLI.
        </AlertDescription>
      </Alert>
      <Alert variant="destructive">
        <TerminalIcon />
        <AlertTitle>Something went wrong</AlertTitle>
        <AlertDescription>Your session has expired.</AlertDescription>
      </Alert>
    </div>
  ),

  "alert-dialog": () => (
    <AlertDialog>
      <AlertDialogTrigger render={<Button variant="outline">Delete</Button>} />
      <AlertDialogContent>
        <AlertDialogHeader>
          <AlertDialogTitle>Are you absolutely sure?</AlertDialogTitle>
          <AlertDialogDescription>
            This cannot be undone.
          </AlertDialogDescription>
        </AlertDialogHeader>
        <AlertDialogFooter>
          <AlertDialogCancel>Cancel</AlertDialogCancel>
          <AlertDialogAction>Continue</AlertDialogAction>
        </AlertDialogFooter>
      </AlertDialogContent>
    </AlertDialog>
  ),

  "aspect-ratio": () => (
    <div className="w-full max-w-sm">
      <AspectRatio
        ratio={16 / 9}
        className="flex items-center justify-center rounded-lg bg-muted text-xs text-muted-foreground"
      >
        16 / 9
      </AspectRatio>
    </div>
  ),

  attachment: () => (
    <Attachment className="w-full max-w-xs">
      <AttachmentMedia>
        <FileTextIcon />
      </AttachmentMedia>
      <AttachmentContent>
        <AttachmentTitle>quarterly-report.pdf</AttachmentTitle>
        <AttachmentDescription>1.2 MB</AttachmentDescription>
      </AttachmentContent>
    </Attachment>
  ),

  avatar: () => (
    <Row>
      <Avatar>
        <AvatarFallback>AB</AvatarFallback>
      </Avatar>
      <AvatarGroup>
        <Avatar>
          <AvatarFallback>CD</AvatarFallback>
        </Avatar>
        <Avatar>
          <AvatarFallback>EF</AvatarFallback>
        </Avatar>
        <AvatarGroupCount>+3</AvatarGroupCount>
      </AvatarGroup>
    </Row>
  ),

  badge: () => (
    <Row>
      <Badge>Default</Badge>
      <Badge variant="secondary">Secondary</Badge>
      <Badge variant="destructive">Destructive</Badge>
      <Badge variant="outline">Outline</Badge>
      <Badge variant="secondary">
        <BadgeCheckIcon />
        Verified
      </Badge>
    </Row>
  ),

  breadcrumb: () => (
    <Breadcrumb>
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
          <BreadcrumbPage>Components</BreadcrumbPage>
        </BreadcrumbItem>
      </BreadcrumbList>
    </Breadcrumb>
  ),

  bubble: () => (
    <div className="flex w-full max-w-sm flex-col gap-2">
      <Bubble>
        <BubbleContent className="bg-muted">
          Did the parity run finish?
        </BubbleContent>
      </Bubble>
      <Bubble align="end">
        <BubbleContent>Mean error 2.953.</BubbleContent>
      </Bubble>
    </div>
  ),

  button: () => (
    <Row>
      <Button>Save</Button>
      <Button variant="secondary">Secondary</Button>
      <Button variant="outline">
        <DownloadIcon />
        Download
      </Button>
      <Button variant="ghost">Ghost</Button>
      <Button variant="destructive">
        <TrashIcon />
        Delete
      </Button>
      <Button variant="link">Link</Button>
      <Button disabled>Disabled</Button>
    </Row>
  ),

  "button-group": () => (
    <ButtonGroup>
      <Button variant="outline">
        <AlignLeftIcon />
      </Button>
      <Button variant="outline">
        <AlignCenterIcon />
      </Button>
      <Button variant="outline">Right</Button>
    </ButtonGroup>
  ),

  calendar: () => (
    <Deferred>
      <Calendar mode="single" className="rounded-lg border" />
    </Deferred>
  ),

  card: () => (
    <Card className="w-full max-w-sm">
      <CardHeader>
        <CardTitle>Create project</CardTitle>
        <CardDescription>Deploy your new project in one click.</CardDescription>
      </CardHeader>
      <CardContent className="text-sm text-muted-foreground">
        Name, framework and region.
      </CardContent>
      <CardFooter className="gap-2">
        <Button variant="outline">Cancel</Button>
        <Button>Deploy</Button>
      </CardFooter>
    </Card>
  ),

  carousel: () => (
    <Carousel className="w-full max-w-xs">
      <CarouselContent>
        {[1, 2, 3, 4, 5].map((n) => (
          <CarouselItem key={n}>
            <Card>
              <CardContent className="flex h-24 items-center justify-center text-2xl font-semibold">
                {n}
              </CardContent>
            </Card>
          </CarouselItem>
        ))}
      </CarouselContent>
      <CarouselPrevious />
      <CarouselNext />
    </Carousel>
  ),

  chart: () => (
    <Deferred>
      <Chart />
    </Deferred>
  ),

  checkbox: () => <CheckboxDemo />,

  collapsible: () => <CollapsibleDemo />,

  combobox: () => <ComboboxPreview />,

  command: () => (
    <Command className="w-full max-w-sm rounded-lg border">
      <CommandInput placeholder="Type a command or search…" />
      <CommandList>
        <CommandGroup heading="Suggestions">
          <CommandItem>
            <SearchIcon />
            Search files
            <CommandShortcut>⌘P</CommandShortcut>
          </CommandItem>
          <CommandItem>
            <SettingsIcon />
            Settings
            <CommandShortcut>⌘,</CommandShortcut>
          </CommandItem>
        </CommandGroup>
      </CommandList>
    </Command>
  ),

  "context-menu": () => (
    <ContextMenu>
      <ContextMenuTrigger className="flex h-24 w-full max-w-xs items-center justify-center rounded-lg border border-dashed text-sm text-muted-foreground">
        Right click here
      </ContextMenuTrigger>
      <ContextMenuContent>
        <ContextMenuItem>
          Open
          <ContextMenuShortcut>⏎</ContextMenuShortcut>
        </ContextMenuItem>
        <ContextMenuItem>Rename</ContextMenuItem>
        <ContextMenuSeparator />
        <ContextMenuItem variant="destructive">Delete</ContextMenuItem>
      </ContextMenuContent>
    </ContextMenu>
  ),

  dialog: () => (
    <Dialog>
      <DialogTrigger render={<Button variant="outline">Edit profile</Button>} />
      <DialogContent>
        <DialogHeader>
          <DialogTitle>Edit profile</DialogTitle>
          <DialogDescription>
            Make changes to your profile here.
          </DialogDescription>
        </DialogHeader>
        <Field>
          <FieldLabel>Name</FieldLabel>
          <Input defaultValue="Palmframe" />
        </Field>
      </DialogContent>
    </Dialog>
  ),

  direction: () => (
    <DirectionProvider direction="rtl">
      <div className="w-full max-w-sm" dir="rtl">
        <Slider defaultValue={[30]} max={100} />
      </div>
    </DirectionProvider>
  ),

  drawer: () => (
    <Drawer>
      <DrawerTrigger render={<Button variant="outline">Open drawer</Button>} />
      <DrawerContent>
        <DrawerHeader>
          <DrawerTitle>Move goal</DrawerTitle>
          <DrawerDescription>Set your daily activity goal.</DrawerDescription>
        </DrawerHeader>
      </DrawerContent>
    </Drawer>
  ),

  "dropdown-menu": () => (
    <DropdownMenu>
      <DropdownMenuTrigger render={<Button variant="outline">Open</Button>} />
      <DropdownMenuContent>
        <DropdownMenuGroup>
          <DropdownMenuLabel>My account</DropdownMenuLabel>
          <DropdownMenuItem>Profile</DropdownMenuItem>
          <DropdownMenuItem>Billing</DropdownMenuItem>
        </DropdownMenuGroup>
        <DropdownMenuSeparator />
        <DropdownMenuGroup>
          <DropdownMenuItem variant="destructive">Log out</DropdownMenuItem>
        </DropdownMenuGroup>
      </DropdownMenuContent>
    </DropdownMenu>
  ),

  empty: () => (
    <Empty className="w-full max-w-sm">
      <EmptyHeader>
        <EmptyMedia variant="icon">
          <SearchIcon />
        </EmptyMedia>
        <EmptyTitle>Scanning</EmptyTitle>
        <EmptyDescription>
          Nothing has advertised yet. This takes a few seconds.
        </EmptyDescription>
      </EmptyHeader>
    </Empty>
  ),

  field: () => (
    <Col>
      <Field>
        <FieldLabel>Email</FieldLabel>
        <Input type="email" placeholder="you@example.com" />
        <FieldDescription>We never share it.</FieldDescription>
      </Field>
    </Col>
  ),

  "hover-card": () => (
    <HoverCard>
      <HoverCardTrigger
        render={<Button variant="link">@palmframe</Button>}
      />
      <HoverCardContent className="w-64 text-sm">
        A Linux distribution where the assistant is part of the system.
      </HoverCardContent>
    </HoverCard>
  ),

  input: () => (
    <Col>
      <Input placeholder="Email" />
      <Input placeholder="Disabled" disabled />
    </Col>
  ),

  "input-group": () => (
    <div className="w-full max-w-sm">
      <InputGroup>
        <InputGroupAddon>
          <SearchIcon />
        </InputGroupAddon>
        <InputGroupInput placeholder="Search components…" />
      </InputGroup>
    </div>
  ),

  "input-otp": () => (
    <InputOTP maxLength={6}>
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

  item: () => (
    <Item variant="outline" className="w-full max-w-sm">
      <ItemMedia variant="icon">
        <FolderIcon />
      </ItemMedia>
      <ItemContent>
        <ItemTitle>Documents</ItemTitle>
        <ItemDescription>42 items</ItemDescription>
      </ItemContent>
      <ItemActions>
        <Button variant="ghost" size="icon-sm">
          <ChevronDownIcon />
        </Button>
      </ItemActions>
    </Item>
  ),

  kbd: () => (
    <Row>
      <KbdGroup>
        <Kbd>Ctrl</Kbd>
        <Kbd>K</Kbd>
      </KbdGroup>
      <KbdGroup>
        <Kbd>Shift</Kbd>
        <Kbd>Tab</Kbd>
      </KbdGroup>
    </Row>
  ),

  label: () => (
    <div className="flex items-center gap-2">
      <Checkbox id="terms" />
      <Label htmlFor="terms">Accept terms and conditions</Label>
    </div>
  ),

  marker: () => (
    <div className="w-full max-w-sm">
      <Marker variant="separator">
        <MarkerContent>Today</MarkerContent>
      </Marker>
    </div>
  ),

  menubar: () => (
    <Menubar>
      <MenubarMenu>
        <MenubarTrigger>File</MenubarTrigger>
        <MenubarContent>
          <MenubarItem>
            New window <MenubarShortcut>⌘N</MenubarShortcut>
          </MenubarItem>
          <MenubarSeparator />
          <MenubarItem>
            Print <MenubarShortcut>⌘P</MenubarShortcut>
          </MenubarItem>
        </MenubarContent>
      </MenubarMenu>
      <MenubarMenu>
        <MenubarTrigger>Edit</MenubarTrigger>
        <MenubarContent>
          <MenubarItem>Undo</MenubarItem>
          <MenubarItem>Redo</MenubarItem>
        </MenubarContent>
      </MenubarMenu>
    </Menubar>
  ),

  message: () => (
    <div className="flex w-full max-w-sm flex-col gap-3">
      <Message>
        <MessageAvatar>
          <Avatar>
            <AvatarFallback>AB</AvatarFallback>
          </Avatar>
        </MessageAvatar>
        <MessageContent>Morning. Parity run is green.</MessageContent>
      </Message>
    </div>
  ),

  "message-scroller": () => (
    <MessageScrollerProvider>
      <MessageScroller className="h-32 w-full max-w-sm">
        <MessageScrollerViewport>
          <MessageScrollerContent>
            {["First", "Second", "Third", "Fourth", "Fifth"].map((m) => (
              <MessageScrollerItem key={m} className="px-3 py-1 text-sm">
                {m}
              </MessageScrollerItem>
            ))}
          </MessageScrollerContent>
        </MessageScrollerViewport>
      </MessageScroller>
    </MessageScrollerProvider>
  ),

  "native-select": () => (
    <div className="w-full max-w-xs">
      <NativeSelect defaultValue="light">
        <NativeSelectOption value="light">Light</NativeSelectOption>
        <NativeSelectOption value="dark">Dark</NativeSelectOption>
        <NativeSelectOption value="system">System</NativeSelectOption>
      </NativeSelect>
    </div>
  ),

  "navigation-menu": () => (
    <NavigationMenu>
      <NavigationMenuList>
        <NavigationMenuItem>
          <NavigationMenuLink href="#">Docs</NavigationMenuLink>
        </NavigationMenuItem>
        <NavigationMenuItem>
          <NavigationMenuLink href="#">Components</NavigationMenuLink>
        </NavigationMenuItem>
      </NavigationMenuList>
    </NavigationMenu>
  ),

  pagination: () => (
    <Pagination>
      <PaginationContent>
        <PaginationItem>
          <PaginationPrevious href="#" />
        </PaginationItem>
        <PaginationItem>
          <PaginationLink href="#" isActive>
            1
          </PaginationLink>
        </PaginationItem>
        <PaginationItem>
          <PaginationLink href="#">2</PaginationLink>
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

  popover: () => (
    <Popover>
      <PopoverTrigger render={<Button variant="outline">Open</Button>} />
      <PopoverContent className="w-72">
        <PopoverHeader>
          <PopoverTitle>Dimensions</PopoverTitle>
          <PopoverDescription>
            Set the dimensions for the layer.
          </PopoverDescription>
        </PopoverHeader>
      </PopoverContent>
    </Popover>
  ),

  progress: () => (
    <div className="w-full max-w-sm">
      <Progress value={66} />
    </div>
  ),

  questionnaire: () => (
    <Col>
      <Field>
        <FieldLabel>How did you hear about us?</FieldLabel>
        <RadioGroup defaultValue="friend" className="gap-2">
          <div className="flex items-center gap-2">
            <RadioGroupItem value="friend" id="q-friend" />
            <Label htmlFor="q-friend">A friend</Label>
          </div>
          <div className="flex items-center gap-2">
            <RadioGroupItem value="search" id="q-search" />
            <Label htmlFor="q-search">Search</Label>
          </div>
        </RadioGroup>
        <FieldDescription>
          The Questionnaire component composes exactly this.
        </FieldDescription>
      </Field>
    </Col>
  ),

  "radio-group": () => (
    <RadioGroup defaultValue="comfortable" className="gap-2">
      {["default", "comfortable", "compact"].map((v) => (
        <div key={v} className="flex items-center gap-2">
          <RadioGroupItem value={v} id={`r-${v}`} />
          <Label htmlFor={`r-${v}`} className="capitalize">
            {v}
          </Label>
        </div>
      ))}
    </RadioGroup>
  ),

  resizable: () => (
    <ResizablePanelGroup
      orientation="horizontal"
      className="h-32 w-full max-w-sm rounded-lg border"
    >
      <ResizablePanel defaultSize={50}>
        <div className="flex h-full items-center justify-center text-sm">
          One
        </div>
      </ResizablePanel>
      <ResizableHandle withHandle />
      <ResizablePanel defaultSize={50}>
        <div className="flex h-full items-center justify-center text-sm">
          Two
        </div>
      </ResizablePanel>
    </ResizablePanelGroup>
  ),

  "scroll-area": () => (
    <ScrollArea className="h-40 w-full max-w-xs rounded-lg border p-3">
      <div className="space-y-1">
        {Array.from({ length: 24 }, (_, i) => (
          <div key={i} className="text-sm">
            Item {i + 1}
          </div>
        ))}
      </div>
    </ScrollArea>
  ),

  select: () => (
    <Select>
      <SelectTrigger className="w-48">
        <SelectValue placeholder="Select a fruit" />
      </SelectTrigger>
      <SelectContent>
        <SelectGroup>
          <SelectLabel>Fruits</SelectLabel>
          <SelectItem value="apple">Apple</SelectItem>
          <SelectItem value="banana">Banana</SelectItem>
          <SelectItem value="blueberry">Blueberry</SelectItem>
        </SelectGroup>
      </SelectContent>
    </Select>
  ),

  separator: () => (
    <div className="w-full max-w-sm space-y-3">
      <p className="text-sm font-medium">palmy</p>
      <Separator />
      <div className="flex h-5 items-center gap-3 text-sm">
        <span>Docs</span>
        <Separator orientation="vertical" />
        <span>Components</span>
        <Separator orientation="vertical" />
        <span>Apps</span>
      </div>
    </div>
  ),

  sheet: () => (
    <Sheet>
      <SheetTrigger render={<Button variant="outline">Open sheet</Button>} />
      <SheetContent side="right">
        <SheetHeader>
          <SheetTitle>Edit profile</SheetTitle>
          <SheetDescription>
            Make changes and save when you are done.
          </SheetDescription>
        </SheetHeader>
      </SheetContent>
    </Sheet>
  ),

  sidebar: () => (
    <div className="h-56 w-full max-w-sm overflow-hidden rounded-lg border">
      <SidebarProvider className="min-h-0">
        <Sidebar collapsible="none" className="h-56">
          <SidebarContent>
            <SidebarGroup>
              <SidebarGroupLabel>Platform</SidebarGroupLabel>
              <SidebarGroupContent>
                <SidebarMenu>
                  <SidebarMenuItem>
                    <SidebarMenuButton isActive>
                      <InboxIcon />
                      <span>Inbox</span>
                    </SidebarMenuButton>
                  </SidebarMenuItem>
                  <SidebarMenuItem>
                    <SidebarMenuButton>
                      <BellIcon />
                      <span>Notifications</span>
                    </SidebarMenuButton>
                  </SidebarMenuItem>
                  <SidebarMenuItem>
                    <SidebarMenuButton>
                      <SettingsIcon />
                      <span>Settings</span>
                    </SidebarMenuButton>
                  </SidebarMenuItem>
                </SidebarMenu>
              </SidebarGroupContent>
            </SidebarGroup>
          </SidebarContent>
        </Sidebar>
      </SidebarProvider>
    </div>
  ),

  skeleton: () => (
    <div className="flex w-full max-w-sm items-center gap-3">
      <Skeleton className="size-10 rounded-full" />
      <div className="flex-1 space-y-2">
        <Skeleton className="h-4 w-full" />
        <Skeleton className="h-4 w-2/3" />
      </div>
    </div>
  ),

  slider: () => (
    <div className="w-full max-w-sm space-y-6">
      <Slider defaultValue={[50]} max={100} step={1} />
      <Slider defaultValue={[25, 75]} max={100} step={1} />
    </div>
  ),

  spinner: () => (
    <Row>
      <Spinner />
      <Button disabled>
        <Spinner />
        Saving
      </Button>
    </Row>
  ),

  switch: () => <SwitchDemo />,

  table: () => (
    <Table className="w-full max-w-md">
      <TableCaption>Recent invoices.</TableCaption>
      <TableHeader>
        <TableRow>
          <TableHead>Invoice</TableHead>
          <TableHead>Status</TableHead>
          <TableHead className="text-right">Amount</TableHead>
        </TableRow>
      </TableHeader>
      <TableBody>
        {[
          ["INV001", "Paid", "$250.00"],
          ["INV002", "Pending", "$150.00"],
          ["INV003", "Unpaid", "$350.00"],
        ].map(([id, status, amount]) => (
          <TableRow key={id}>
            <TableCell className="font-medium">{id}</TableCell>
            <TableCell>{status}</TableCell>
            <TableCell className="text-right">{amount}</TableCell>
          </TableRow>
        ))}
      </TableBody>
    </Table>
  ),

  tabs: () => (
    <Tabs defaultValue="account" className="w-full max-w-sm">
      <TabsList>
        <TabsTrigger value="account">Account</TabsTrigger>
        <TabsTrigger value="password">Password</TabsTrigger>
      </TabsList>
      <TabsContent value="account" className="pt-3 text-sm text-muted-foreground">
        Make changes to your account here.
      </TabsContent>
      <TabsContent
        value="password"
        className="pt-3 text-sm text-muted-foreground"
      >
        Change your password here.
      </TabsContent>
    </Tabs>
  ),

  textarea: () => (
    <div className="w-full max-w-sm">
      <Textarea placeholder="Type your message here." />
    </div>
  ),

  toast: () => <ToastDemo />,

  toggle: () => (
    <Row>
      <TogglePressed />
      <Toggle aria-label="Italic">
        <ItalicIcon />
      </Toggle>
    </Row>
  ),

  "toggle-group": () => (
    <ToggleGroup defaultValue={["bold"]}>
      <ToggleGroupItem value="bold" aria-label="Bold">
        <BoldIcon />
      </ToggleGroupItem>
      <ToggleGroupItem value="italic" aria-label="Italic">
        <ItalicIcon />
      </ToggleGroupItem>
      <ToggleGroupItem value="underline" aria-label="Underline">
        <UnderlineIcon />
      </ToggleGroupItem>
    </ToggleGroup>
  ),

  tooltip: () => (
    <Tooltip>
      <TooltipTrigger render={<Button variant="outline">Hover me</Button>} />
      <TooltipContent>Add to library</TooltipContent>
    </Tooltip>
  ),
};
