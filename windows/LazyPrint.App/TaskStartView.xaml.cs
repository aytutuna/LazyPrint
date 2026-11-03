using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using LazyPrint.Core;

namespace LazyPrint.App;

/// <summary>
/// The start screen: one tile per task (<see cref="TaskCatalog"/>) in its group (<see cref="TaskGroups"/>), greyed out
/// with a short reason when it cannot be started. Picking a tile is reported to the window, which sets it up and opens
/// the print screen. The twin of UI/TaskStartView.swift.
/// </summary>
public partial class TaskStartView : UserControl
{
    /// <summary>The side insets of the groups' headings (see <see cref="UpdateInsets"/>).</summary>
    public static readonly DependencyProperty HeaderMarginProperty = DependencyProperty.Register(
        nameof(HeaderMargin), typeof(Thickness), typeof(TaskStartView), new PropertyMetadata(new Thickness(16, 16, 16, 2)));

    /// <summary>The side insets of the groups' tiles.</summary>
    public static readonly DependencyProperty GridMarginProperty = DependencyProperty.Register(
        nameof(GridMargin), typeof(Thickness), typeof(TaskStartView), new PropertyMetadata(new Thickness(10, 0, 10, 0)));

    /// <summary>A tile's width (168) and its margin on both sides (6).</summary>
    internal const double TileSlotWidth = 168 + 2 * GridInsets.CardMargin;

    private AppViewModel? _viewModel;
    private List<TaskGroupItem> _groups = [];

    /// <summary>A task tile was picked.</summary>
    public event Action<PrintTask>? TaskChosen;

    public TaskStartView()
    {
        InitializeComponent();
    }

    public Thickness HeaderMargin
    {
        get => (Thickness)GetValue(HeaderMarginProperty);
        set => SetValue(HeaderMarginProperty, value);
    }

    public Thickness GridMargin
    {
        get => (Thickness)GetValue(GridMarginProperty);
        set => SetValue(GridMarginProperty, value);
    }

    public void Attach(AppViewModel viewModel)
    {
        _viewModel = viewModel;
        Refresh();
    }

    /// <summary>
    /// Updates the tiles from the view model. The groups are rebuilt only when a tile changed, so
    /// keyboard focus stays on the tile it was on.
    /// </summary>
    public void Refresh()
    {
        if (_viewModel is not { } vm) return;

        var cards = vm.TaskCards;
        var groups = TaskGroups.All
            .Select(group => new TaskGroupItem(group.Title(), [.. cards.Where(card => card.Definition.Group == group)]))
            .Where(group => group.Cards.Count > 0)
            .ToList();
        if (!groups.Select(g => g.Signature).SequenceEqual(_groups.Select(g => g.Signature)))
        {
            _groups = groups;
            TaskGrid.ItemsSource = _groups;
        }

        // The tiles replace the settings, which a job in progress works from a snapshot of: they wait until it ends.
        TaskGrid.IsEnabled = !vm.IsBusy;
    }

    /// <summary>The task tiles on screen, in reading order (group by group).</summary>
    internal List<Button> TaskTiles()
    {
        UpdateLayout();
        var tiles = new List<Button>();
        void Walk(DependencyObject node)
        {
            for (int i = 0; i < VisualTreeHelper.GetChildrenCount(node); i++)
            {
                var child = VisualTreeHelper.GetChild(node, i);
                if (child is Button { Name: "Card", DataContext: TaskCardItem } button) tiles.Add(button);
                else Walk(child);
            }
        }
        Walk(TaskGrid);
        return tiles;
    }

    /// <summary>
    /// Puts keyboard focus on the current task's tile (else the first tile that can be started),
    /// so a returning user can press Enter to carry on.
    /// </summary>
    public void FocusDefaultCard()
    {
        var tiles = TaskTiles();
        var preferred = tiles.FirstOrDefault(b => b.DataContext is TaskCardItem { IsCurrent: true, IsAvailable: true })
                        ?? tiles.FirstOrDefault(b => b.DataContext is TaskCardItem { IsAvailable: true });
        if (preferred is null) return;
        preferred.Focus();
        Keyboard.Focus(preferred);
    }

    private void TaskCard_Click(object sender, RoutedEventArgs e)
    {
        if (sender is FrameworkElement { DataContext: TaskCardItem card } && card.IsAvailable)
        {
            TaskChosen?.Invoke(card.Task);
        }
    }

    /// <summary>The scroll viewport changed width (resize, scrollbar shown or hidden): re-centre the tiles.</summary>
    private void Scroller_ScrollChanged(object sender, ScrollChangedEventArgs e)
    {
        if (e.ViewportWidthChange != 0) UpdateInsets();
    }

    /// <summary>
    /// Centre the tiles: split the width left over after the last whole column between both sides,
    /// and line the header and the group headings up with the tiles' outer edges.
    /// </summary>
    private void UpdateInsets()
    {
        var (cards, header) = GridInsets.For(Scroller.ViewportWidth, slotWidth: TileSlotWidth);
        GridMargin = new Thickness(cards.Left, 0, cards.Right, 0);
        HeaderMargin = new Thickness(header.Left, 16, header.Right, 2);
        Header.Margin = new Thickness(header.Left, 20, header.Right, 4);
    }
}

/// <summary>A group of task tiles on the start screen ("Documents").</summary>
public sealed class TaskGroupItem(string title, IReadOnlyList<TaskCardItem> cards)
{
    public string Title { get; } = title;
    public IReadOnlyList<TaskCardItem> Cards { get; } = cards;

    internal string Signature => Title + "\u001e" + string.Join('\u001e', Cards.Select(c => c.Signature));
}
