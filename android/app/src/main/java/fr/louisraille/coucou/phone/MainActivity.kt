package fr.louisraille.coucou.phone

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import androidx.activity.compose.setContent
import androidx.fragment.app.FragmentActivity
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.activity.viewModels
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.ui.Modifier

class MainActivity : FragmentActivity() {

    private val vm: CoucouViewModel by viewModels()
    private val notifPermission =
        registerForActivityResult(ActivityResultContracts.RequestPermission()) { }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // The app is the island — draw behind the bars; screens pad themselves.
        enableEdgeToEdge()
        Notifier.ensureChannel(this)
        if (Build.VERSION.SDK_INT >= 33 &&
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
        ) {
            notifPermission.launch(Manifest.permission.POST_NOTIFICATIONS)
        }
        setContent {
            CoucouTheme {
                Surface(Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
                    when (vm.screen) {
                        CoucouViewModel.Screen.PAIR -> PairScreen(vm)
                        CoucouViewModel.Screen.HOME -> HomeScreen(vm)
                        CoucouViewModel.Screen.PICKER -> PickerScreen(vm)
                        CoucouViewModel.Screen.CHAT -> ChatScreen(vm)
                    }
                }
            }
        }
    }

    // The 3 s relay poll only runs while the island can actually be looked at.
    override fun onStart() {
        super.onStart()
        vm.onForeground()
    }

    override fun onStop() {
        super.onStop()
        vm.onBackground()
    }
}
